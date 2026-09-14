unit uLogger;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uAppConfig;

type
  // Tingkat keparahan log untuk memudahkan pemfilteran masalah
  TLogLevel = (llInfo, llWarning, llError, llDebug);

  { TLogger }
  // Menggunakan pola Singleton seperti AppConfig
  TLogger = class
  private
    FLock: TCriticalSection;
    FCurrentDate: TDate;
    FLogFileName: string;

    class var FInstance: TLogger;

    procedure UpdateLogFileName;
  public
    constructor Create;
    destructor Destroy; override;

    class function Instance: TLogger;

    // Method utama untuk mencatat log
    procedure Log(const AMessage: string; const ALevel: TLogLevel = llInfo);
  end;

implementation

const
  LOG_LEVEL_STR: array[TLogLevel] of string = ('INFO', 'WARN', 'ERROR', 'DEBUG');

{ TLogger }

constructor TLogger.Create;
begin
  // TCriticalSection mengantrekan thread yang mencoba menulis log di saat bersamaan
  FLock := TCriticalSection.Create;
  UpdateLogFileName;
end;

destructor TLogger.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

class function TLogger.Instance: TLogger;
begin
  if not Assigned(FInstance) then
    FInstance := TLogger.Create;
  Result := FInstance;
end;

procedure TLogger.UpdateLogFileName;
var
  LogDir: string;
begin
  // Rotasi log harian: Nama file berubah otomatis saat berganti hari
  FCurrentDate := Date;
  LogDir := TAppConfig.Instance.LogPath;

  // PERBAIKAN: Menggunakan IncludeTrailingPathDelimiter alih-alih TPath
  // Format file log: BulkEmailer_YYYY-MM-DD.log
  FLogFileName := IncludeTrailingPathDelimiter(LogDir) + 'BulkEmailer_' + FormatDateTime('yyyy-mm-dd', FCurrentDate) + '.log';
end;

procedure TLogger.Log(const AMessage: string; const ALevel: TLogLevel);
var
  LogFile: TextFile;
  FormattedMsg: string;
begin
  // Format standar log: [Waktu] [LEVEL] Pesan
  FormattedMsg := Format('[%s] [%-5s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), LOG_LEVEL_STR[ALevel], AMessage]);

  // Mengunci akses eksekusi. Hanya 1 thread yang bisa melewati blok ini dalam satu waktu
  FLock.Acquire;
  try
    // Cek apakah hari sudah berganti untuk rotasi log harian
    if Date <> FCurrentDate then
      UpdateLogFileName;

    AssignFile(LogFile, FLogFileName);
    try
      // Mode efisien: Buka dan tambahkan di baris baru. Jika belum ada, buat baru.
      if FileExists(FLogFileName) then
        Append(LogFile)
      else
        Rewrite(LogFile);

      Writeln(LogFile, FormattedMsg);
    finally
      CloseFile(LogFile);
    end;
  except
    // Dalam sistem Logger, sangat penting menelan exception (silent fail)
    // agar error pada penulisan log tidak membuat aplikasi utama crash.
    on E: Exception do
    begin
      // Bisa dikembangkan untuk menulis ke Event Viewer OS jika sangat kritis
    end;
  end;

  // Melepaskan kunci agar thread lain yang mengantre bisa menulis log
  FLock.Release;
end;

initialization
  TLogger.FInstance := nil;

finalization
  if Assigned(TLogger.FInstance) then
    TLogger.FInstance.Free;

end.
