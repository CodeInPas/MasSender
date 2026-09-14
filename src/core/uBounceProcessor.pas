unit uBounceProcessor;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, RegExpr, sqldb, sqlite3conn,
  IdIMAP4, IdMessage, IdSSLOpenSSL, IdExplicitTLSClientServerBase,
  uContactRepo, uSmtpRepo, uDbConnection, uAppConfig, uLogger;

type
  { TBounceProcessor }
  // Thread ini akan berjalan di background selamanya selama aplikasi aktif,
  // bertugas memungut email bounce dari kotak masuk IMAP.
  TBounceProcessor = class(TThread)
  private
    FProfile: TSmtpProfile;
    FCheckIntervalSec: Integer;

    // Fungsi untuk menganalisis teks email dan mencari alamat email yang gagal
    // PERBAIKAN: Menerima koneksi lokal agar thread-safe saat melakukan UPDATE
    procedure ProcessBouncedMessage(AMsg: TIdMessage; AConn: TSQLite3Connection; ATrans: TSQLTransaction);

    // Fungsi helper untuk mendapatkan alamat Host IMAP berdasarkan Host SMTP
    function GetImapHost(const ASmtpHost: string): string;
  protected
    procedure Execute; override;
  public
    // Interval bawaan adalah 1800 detik (30 menit)
    constructor Create(const AProfile: TSmtpProfile; AIntervalSeconds: Integer = 1800);
  end;

implementation

{ TBounceProcessor }

constructor TBounceProcessor.Create(const AProfile: TSmtpProfile; AIntervalSeconds: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := True;

  FProfile := AProfile;
  FCheckIntervalSec := AIntervalSeconds;
end;

function TBounceProcessor.GetImapHost(const ASmtpHost: string): string;
begin
  // Fallback sederhana: Biasanya host IMAP dan SMTP berada di domain yang sama (misal: mail.domain.com).
  // Jika klien menggunakan konvensi smtp.domain.com, kita ubah otomatis menjadi imap.domain.com.
  Result := ASmtpHost;
  if Pos('smtp.', LowerCase(Result)) = 1 then
    Result := StringReplace(Result, 'smtp.', 'imap.', [rfIgnoreCase])
  else if Pos('send.', LowerCase(Result)) = 1 then
    Result := StringReplace(Result, 'send.', 'imap.', [rfIgnoreCase]);
end;

procedure TBounceProcessor.ProcessBouncedMessage(AMsg: TIdMessage; AConn: TSQLite3Connection; ATrans: TSQLTransaction);
var
  Regex: TRegExpr;
  BodyText, BouncedEmail: string;
  Qry: TSQLQuery;
begin
  // Ambil teks dari body email
  BodyText := AMsg.Body.Text;

  // Inisialisasi Regular Expression
  Regex := TRegExpr.Create;
  try
    // Pola 1: Mencari format standar DSN (Delivery Status Notification)
    // Contoh: "Final-Recipient: rfc822; email.mati@domain.com"
    Regex.ModifierI := True; // Case-insensitive
    Regex.Expression := 'Final-Recipient:\s*rfc822;\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})';

    if Regex.Exec(BodyText) then
    begin
      BouncedEmail := Regex.Match[1];
    end
    else
    begin
      // Pola 2: Fallback memindai teks untuk melihat jika sistem MTA lain
      // menuliskan alamat email setelah kata "failed" atau "undeliverable"
      Regex.Expression := '(?:failed to deliver to|undeliverable address:?|delivery to)\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})';
      if Regex.Exec(BodyText) then
        BouncedEmail := Regex.Match[1];
    end;

    // Jika alamat email yang memantul berhasil diekstrak
    if BouncedEmail <> '' then
    begin
      TLogger.Instance.Log(Format('IMAP Processor: Mendeteksi Bounce untuk %s', [BouncedEmail]), llInfo);

      // Update tabel kontak
      TContactRepo.UpdateStatus(BouncedEmail, 'Bounced');

      // PERBAIKAN: Update tabel send_logs (Penting untuk kalkulasi Circuit Breaker)
      Qry := TSQLQuery.Create(nil);
      try
        Qry.DataBase := AConn;
        Qry.Transaction := ATrans;
        // Cari ID Kontak berdasarkan email, lalu ubah log pengirimannya menjadi Bounced
        Qry.SQL.Text := 'UPDATE send_logs SET status = ''Bounced'' ' +
                        'WHERE contact_id = (SELECT id FROM contacts WHERE email = :email LIMIT 1) ' +
                        'AND status = ''Sent''';
        Qry.ParamByName('email').AsString := BouncedEmail;

        ATrans.StartTransaction;
        Qry.ExecSQL;
        ATrans.Commit;
      except
        on E: Exception do
        begin
          if ATrans.Active then ATrans.Rollback;
          TLogger.Instance.Log('Gagal mencatat bounce ke send_logs: ' + E.Message, llError);
        end;
      end;
      Qry.Free;
    end;
  finally
    Regex.Free;
  end;
end;

procedure TBounceProcessor.Execute;
var
  IMAP: TIdIMAP4;
  Msg: TIdMessage;
  SSLHandler: TIdSSLIOHandlerSocketOpenSSL;
  SearchArr: array of TIdIMAP4SearchRec;
  i, WaitSec: Integer;

  // Koneksi database dan variabel Circuit Breaker
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  CbReason: string;
begin
  TLogger.Instance.Log(Format('Bounce Processor dimulai untuk profil: %s', [FProfile.Username]), llInfo);

  IMAP := TIdIMAP4.Create(nil);
  Msg := TIdMessage.Create(nil);
  SSLHandler := TIdSSLIOHandlerSocketOpenSSL.Create(nil);

  // Membuat koneksi lokal yang aman dari bentrokan multithreading
  Conn := TDbManager.Instance.CreateNewConnection(Trans);

  try
    // IMAP Port standar untuk SSL/TLS adalah 993
    SSLHandler.SSLOptions.Method := sslvTLSv1_2;
    SSLHandler.SSLOptions.Mode := sslmClient;

    IMAP.IOHandler := SSLHandler;
    IMAP.Host := GetImapHost(FProfile.Host);
    IMAP.Port := 993; // Implicit TLS
    IMAP.UseTLS := utUseImplicitTLS;
    IMAP.Username := FProfile.Username;
    IMAP.Password := FProfile.Password;

    while not Terminated do
    begin
      try
        if not IMAP.Connected then
        begin
          IMAP.Connect;
          IMAP.SelectMailBox('INBOX');
        end;

        SetLength(SearchArr, 1);
        SearchArr[0].SearchKey := skUnseen;

        if IMAP.SearchMailBox(SearchArr) then
        begin
          for i := 0 to High(IMAP.MailBox.SearchResult) do
          begin
            if Terminated then Break;

            Msg.Clear;
            IMAP.Retrieve(IMAP.MailBox.SearchResult[i], Msg);

            // Periksa apakah ini email pantulan (MAILER-DAEMON)
            if Pos('mailer-daemon', LowerCase(Msg.From.Address)) > 0 then
            begin
              // Kirim koneksi database ke fungsi parser
              ProcessBouncedMessage(Msg, Conn, Trans);
            end;

            IMAP.StoreFlags(IMAP.MailBox.SearchResult[i], sdReplace, [mfSeen, mfDeleted]);
          end;

          IMAP.ExpungeMailBox;

          // PERBAIKAN: Secara proaktif mengecek Circuit Breaker setelah membersihkan batch email Bounce
          if TSmtpRepo.IsCircuitBreakerTripped(
               TAppConfig.Instance.CbMinHealthScore,
               TAppConfig.Instance.CbMaxBounceRate,
               TAppConfig.Instance.CbTimeWindowMin,
               CbReason) then
          begin
            TLogger.Instance.Log('⚠️ CIRCUIT BREAKER TERPICU (Deteksi IMAP): ' + CbReason, llError);
            // Master Thread (SmtpDispatcher) akan membaca log ini dan otomatis melakukan Pause.
          end;
        end;

      except
        on E: Exception do
        begin
          TLogger.Instance.Log('IMAP Error: ' + E.Message, llError);
          if IMAP.Connected then
            IMAP.Disconnect;
        end;
      end;

      // MICRO-SLEEP LOOP (Sangat Penting!)
      for WaitSec := 1 to FCheckIntervalSec do
      begin
        if Terminated then Break;
        Sleep(1000);
      end;
    end;

  finally
    if IMAP.Connected then
      IMAP.Disconnect;

    Conn.Free;
    SSLHandler.Free;
    Msg.Free;
    IMAP.Free;

    TLogger.Instance.Log('Bounce Processor dihentikan.', llInfo);
  end;
end;

end.
