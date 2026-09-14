unit uAppConfig;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, IniFiles;

type

  { TAppConfig }
  TAppConfig = class
  private
    FAppPath: string;
    FDbPath: string;
    FLogPath: string;
    FWebTrackingUrl: string;
    FMaxWorkerThreads: Integer;
    FConfigFilePath: string;

    FCbMaxBounceRate: Integer;
    FCbMinHealthScore: Integer;
    FCbTimeWindowMin: Integer;

    class var FInstance: TAppConfig;

    procedure SetMaxWorkerThreads(const AValue: Integer);
    procedure SetWebTrackingUrl(const AValue: string);
  public
    constructor Create;
    destructor Destroy; override;

    class function Instance: TAppConfig;

    procedure LoadConfig;
    procedure SaveConfig;
    procedure EnsureDirectoriesExist;

    property AppPath: string read FAppPath;
    property DbPath: string read FDbPath;
    property LogPath: string read FLogPath;

    property WebTrackingUrl: string read FWebTrackingUrl write SetWebTrackingUrl;
    property MaxWorkerThreads: Integer read FMaxWorkerThreads write SetMaxWorkerThreads;

    property CbMaxBounceRate: Integer read FCbMaxBounceRate write FCbMaxBounceRate;
    property CbMinHealthScore: Integer read FCbMinHealthScore write FCbMinHealthScore;
    property CbTimeWindowMin: Integer read FCbTimeWindowMin write FCbTimeWindowMin;
  end;

implementation

{ TAppConfig }

constructor TAppConfig.Create;
begin
  FAppPath := ExtractFilePath(ParamStr(0));

  FDbPath := IncludeTrailingPathDelimiter(FAppPath) + 'db';
  FLogPath := IncludeTrailingPathDelimiter(FAppPath) + 'logs';
  FConfigFilePath := IncludeTrailingPathDelimiter(FAppPath) + 'config.ini';

  FMaxWorkerThreads := 3;
  FWebTrackingUrl := 'https://your-domain.com/tracker.php';

  FCbMaxBounceRate := 10;
  FCbMinHealthScore := 50;
  FCbTimeWindowMin := 60;

  EnsureDirectoriesExist;
  LoadConfig;
end;

destructor TAppConfig.Destroy;
begin
  SaveConfig;
  inherited Destroy;
end;

class function TAppConfig.Instance: TAppConfig;
begin
  if not Assigned(FInstance) then
    FInstance := TAppConfig.Create;
  Result := FInstance;
end;

procedure TAppConfig.SetMaxWorkerThreads(const AValue: Integer);
begin
  if FMaxWorkerThreads = AValue then Exit;
  if (AValue > 0) and (AValue <= 20) then
    FMaxWorkerThreads := AValue;
end;

procedure TAppConfig.SetWebTrackingUrl(const AValue: string);
begin
  if FWebTrackingUrl = AValue then Exit;
  FWebTrackingUrl := AValue;
end;

procedure TAppConfig.EnsureDirectoriesExist;
begin
  if not DirectoryExists(FDbPath) then ForceDirectories(FDbPath);
  if not DirectoryExists(FLogPath) then ForceDirectories(FLogPath);
end;

procedure TAppConfig.LoadConfig;
var
  Ini: TMemIniFile;
  TmpStr: string;
begin
  Ini := TMemIniFile.Create(FConfigFilePath);
  try
    // PERBAIKAN: Membaca sebagai String lalu diparsing dengan aman menggunakan StrToIntDef
    // Ini mencegah EConvertError jika value di config.ini kosong (=)

    TmpStr := Ini.ReadString('Core', 'MaxWorkerThreads', IntToStr(FMaxWorkerThreads));
    FMaxWorkerThreads := StrToIntDef(Trim(TmpStr), FMaxWorkerThreads);

    FWebTrackingUrl := Ini.ReadString('API', 'WebTrackingUrl', FWebTrackingUrl);

    TmpStr := Ini.ReadString('CircuitBreaker', 'MaxBounceRate', IntToStr(FCbMaxBounceRate));
    FCbMaxBounceRate := StrToIntDef(Trim(TmpStr), FCbMaxBounceRate);

    TmpStr := Ini.ReadString('CircuitBreaker', 'MinHealthScore', IntToStr(FCbMinHealthScore));
    FCbMinHealthScore := StrToIntDef(Trim(TmpStr), FCbMinHealthScore);

    TmpStr := Ini.ReadString('CircuitBreaker', 'TimeWindowMin', IntToStr(FCbTimeWindowMin));
    FCbTimeWindowMin := StrToIntDef(Trim(TmpStr), FCbTimeWindowMin);
  finally
    Ini.Free;
  end;
end;

procedure TAppConfig.SaveConfig;
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(FConfigFilePath);
  try
    Ini.WriteInteger('Core', 'MaxWorkerThreads', FMaxWorkerThreads);
    Ini.WriteString('API', 'WebTrackingUrl', FWebTrackingUrl);

    Ini.WriteInteger('CircuitBreaker', 'MaxBounceRate', FCbMaxBounceRate);
    Ini.WriteInteger('CircuitBreaker', 'MinHealthScore', FCbMinHealthScore);
    Ini.WriteInteger('CircuitBreaker', 'TimeWindowMin', FCbTimeWindowMin);

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

initialization
  TAppConfig.FInstance := nil;

finalization
  if Assigned(TAppConfig.FInstance) then
    TAppConfig.FInstance.Free;

end.
