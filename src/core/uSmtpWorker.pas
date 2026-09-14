unit uSmtpWorker;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn,
  IdSMTP, IdMessage, IdSSLOpenSSL, IdExplicitTLSClientServerBase,
  uContactRepo, uCampaignRepo, uSmtpRepo, uDbConnection, uLogger, uLicenseManager,
  uAiSpintax;

type
  { TSmtpWorker }

  TSmtpWorker = class(TThread)
  private
    FContacts: TContactArray;
    FCampaign: TCampaign;
    FProfile: TSmtpProfile;

    // Logic with a retry system to prevent Multi-Thread Lock (database is locked)
    procedure LogSendStatus(AConn: TSQLite3Connection; ATrans: TSQLTransaction;
                            AContactID: Integer; const AStatus, AMsgID: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const AContacts: TContactArray; const ACampaign: TCampaign; const AProfile: TSmtpProfile);
  end;

implementation

{ TSmtpWorker }

constructor TSmtpWorker.Create(const AContacts: TContactArray; const ACampaign: TCampaign; const AProfile: TSmtpProfile);
begin
  inherited Create(False);
  FreeOnTerminate := True;

  FContacts := AContacts;
  FCampaign := ACampaign;
  FProfile := AProfile;
end;

procedure TSmtpWorker.LogSendStatus(AConn: TSQLite3Connection; ATrans: TSQLTransaction;
                                    AContactID: Integer; const AStatus, AMsgID: string);
var
  Qry: TSQLQuery;
  Retries: Integer;
  Success: Boolean;
begin
  Qry := TSQLQuery.Create(nil);
  Retries := 0;
  Success := False;
  try
    Qry.DataBase := AConn;
    Qry.Transaction := ATrans;
    Qry.SQL.Text := 'INSERT INTO send_logs (contact_id, campaign_id, smtp_id, status, message_id) ' +
                    'VALUES (:cid, :campid, :smtpid, :status, :msgid)';
    Qry.ParamByName('cid').AsInteger := AContactID;
    Qry.ParamByName('campid').AsInteger := FCampaign.ID;
    Qry.ParamByName('smtpid').AsInteger := FProfile.ID;
    Qry.ParamByName('status').AsString := AStatus;
    Qry.ParamByName('msgid').AsString := AMsgID;

    // FIX: Retry Backoff System if SQLite "Database is Locked" by another thread
    while (Retries < 5) and (not Success) do
    begin
      try
        if not ATrans.Active then ATrans.StartTransaction;
        Qry.ExecSQL;

        // Also update the main contact status from Queued to Sent/Failed
        Qry.Close; // Safe because the transaction dataset is active via the first ExecSQL
        Qry.SQL.Text := 'UPDATE contacts SET status = :status WHERE id = :cid';
        Qry.ParamByName('status').AsString := AStatus;
        Qry.ParamByName('cid').AsInteger := AContactID;
        Qry.ExecSQL;

        ATrans.Commit;
        Success := True;
      except
        on E: Exception do
        begin
          if ATrans.Active then ATrans.Rollback;
          // SQLite returns a "database is locked" error if a multi-thread collision occurs
          if Pos('locked', LowerCase(E.Message)) > 0 then
          begin
            Inc(Retries);
            Sleep(100 + Random(300)); // Randomize delay to break free from simultaneous collisions
          end
          else
          begin
            TLogger.Instance.Log('Failed to write to send_logs: ' + E.Message, llError);
            Break; // Other fatal errors (not locked), stop retry
          end;
        end;
      end;
    end;
  finally
    Qry.Free;
  end;
end;

procedure TSmtpWorker.Execute;
var
  SMTP: TIdSMTP;
  Msg: TIdMessage;
  SSLHandler: TIdSSLIOHandlerSocketOpenSSL;
  i, Jitter, ActualDelay: Integer;
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  GeneratedMsgID: string;
  ProcessedBody: string;
begin
  if Length(FContacts) = 0 then Exit;

  TLogger.Instance.Log(Format('Worker starting batch of %d emails via SMTP: %s', [Length(FContacts), FProfile.Host]), llInfo);

  SMTP := TIdSMTP.Create(nil);
  Msg := TIdMessage.Create(nil);
  SSLHandler := TIdSSLIOHandlerSocketOpenSSL.Create(nil);

  Conn := TDbManager.Instance.CreateNewConnection(Trans);

  try
    try
      SSLHandler.SSLOptions.Method := sslvTLSv1_2;
      SSLHandler.SSLOptions.Mode := sslmClient;

      // FIX: Bypass encryption if using Local SMTP
      if (FProfile.Host = '127.0.0.1') or (LowerCase(FProfile.Host) = 'localhost') then
      begin
        SMTP.IOHandler := nil;         // Do not use SSL Handler
        SMTP.UseTLS := utNoTLSSupport; // Disable TLS
      end
      else
      begin
        SMTP.IOHandler := SSLHandler;
        if FProfile.Port = 465 then
          SMTP.UseTLS := utUseImplicitTLS
        else
          SMTP.UseTLS := utUseExplicitTLS;
      end;

      SMTP.Host := FProfile.Host;
      SMTP.Port := FProfile.Port;
      SMTP.Username := FProfile.Username;
      SMTP.Password := FProfile.Password;

      SMTP.Connect;

      // Authenticate only if Username is present (Local servers usually do not require login)
      if Trim(FProfile.Username) <> '' then
        SMTP.Authenticate;

      TSmtpRepo.UpdateHealthScore(FProfile.ID, 1);

      for i := 0 to High(FContacts) do
      begin
        if Terminated then Break;

        if not TLicenseManager.Instance.CanSendEmail then
        begin
          TLogger.Instance.Log('Trial sending limit reached. Worker stopped.', llWarning);
          Break;
        end;

        Msg.Clear;

        // Double check: Ensure "From" field is valid even if Username is empty locally
        if Trim(FProfile.Username) <> '' then
          Msg.From.Address := FProfile.Username
        else
          Msg.From.Address := 'tester@localhost'; // Safe fallback for local mock servers

        Msg.Recipients.EMailAddresses := FContacts[i].Email;
        Msg.Subject := EvaluateSpintax(FCampaign.Name);

        ProcessedBody := EvaluateSpintax(FCampaign.TemplateText);

        if Trim(FContacts[i].Name) <> '' then
          ProcessedBody := StringReplace(ProcessedBody, '[Name]', Trim(FContacts[i].Name), [rfReplaceAll, rfIgnoreCase])
        else
          ProcessedBody := StringReplace(ProcessedBody, '[Name]', 'Customer', [rfReplaceAll, rfIgnoreCase]);

        Msg.Body.Text := ProcessedBody;

        try
          SMTP.Send(Msg);
          GeneratedMsgID := Msg.MsgId;

          LogSendStatus(Conn, Trans, FContacts[i].ID, 'Sent', GeneratedMsgID);
          TLicenseManager.Instance.RecordEmailSent;
        except
          on E: Exception do
          begin
            LogSendStatus(Conn, Trans, FContacts[i].ID, 'Failed', '');
            TLogger.Instance.Log(Format('Failed to send to %s: %s', [FContacts[i].Email, E.Message]), llError);
            TSmtpRepo.UpdateHealthScore(FProfile.ID, -2);
          end;
        end;

        if i < High(FContacts) then
        begin
          Jitter := Round(FProfile.DelayMS * 0.2);
          ActualDelay := (FProfile.DelayMS - Jitter) + Random(Jitter * 2 + 1);
          Sleep(ActualDelay);
        end;
      end;

    except
      on E: Exception do
      begin
        TLogger.Instance.Log('SMTP Connection Dropped/Failed: ' + E.Message, llError);
        TSmtpRepo.UpdateHealthScore(FProfile.ID, -10);
      end;
    end;
  finally
    if SMTP.Connected then
      SMTP.Disconnect;

    Conn.Free;
    SSLHandler.Free;
    Msg.Free;
    SMTP.Free;
  end;
end;

end.
