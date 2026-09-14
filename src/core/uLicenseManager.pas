unit uLicenseManager;

{$mode ObjFPC}{$H+}

interface

uses
  {$IFDEF WINDOWS}
  Windows, // Moved to the front so its TCriticalSection record type is overridden by SyncObjs
  {$ENDIF}
  Classes, SysUtils, SyncObjs, md5, uAppConfig, uLogger;

const
  TRIAL_MAX_EMAILS = 5000;
  LICENSE_SALT = 'B3t4_S3cr3t_2026'; // Secret cryptographic salt

type
  { TLicenseManager }
  // Using the Singleton pattern. This class controls the activation status
  // and limits the number of sends if it is still in Trial mode.
  TLicenseManager = class
  private
    FLock: TCriticalSection;
    FIsRegistered: Boolean;
    FTrialEmailsSent: Integer;
    FHardwareID: string;

    class var FInstance: TLicenseManager;

    function GenerateHardwareID: string;
    procedure LoadLicenseState;
  public
    constructor Create;
    destructor Destroy; override;

    class function Instance: TLicenseManager;

    // Validates and saves the license key.
    function ActivateLicense(const AKey: string): Boolean;

    // Checks if the application is ready to send (Full, or Trial quota is not exhausted)
    function CanSendEmail: Boolean;

    // Called by the Dispatcher/Worker thread every time 1 email is successfully sent.
    procedure RecordEmailSent;

    property IsRegistered: Boolean read FIsRegistered;
    property HardwareID: string read FHardwareID;
    property TrialEmailsSent: Integer read FTrialEmailsSent;
  end;

implementation

{ TLicenseManager }

constructor TLicenseManager.Create;
begin
  FLock := TCriticalSection.Create;
  FHardwareID := GenerateHardwareID;
  FTrialEmailsSent := 0;
  FIsRegistered := False;
  LoadLicenseState;
end;

destructor TLicenseManager.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

class function TLicenseManager.Instance: TLicenseManager;
begin
  if not Assigned(FInstance) then
    FInstance := TLicenseManager.Create;
  Result := FInstance;
end;

function TLicenseManager.GenerateHardwareID: string;
{$IFDEF WINDOWS}
var
  VolumeSerialNumber: DWORD;
  MaximumComponentLength: DWORD;
  FileSystemFlags: DWORD;
begin
  // Highly efficient: Retrieves the Serial Number from the disk partition (C:\)
  // as a unique Hardware ID (HWID) to lock the license to the client computer.
  if GetVolumeInformation(PChar('C:\'), nil, 0, @VolumeSerialNumber,
                          MaximumComponentLength, FileSystemFlags, nil, 0) then
  begin
    Result := IntToHex(VolumeSerialNumber, 8);
  end
  else
    Result := 'UNKNOWN-HWID';
end;
{$ELSE}
begin
  // Secondary fallback if compiled outside of Windows
  Result := 'GENERIC-' + GetEnvironmentVariable('HOSTNAME');
end;
{$ENDIF}

procedure TLicenseManager.LoadLicenseState;
var
  ConfigFile: string;
  SavedKey: string;
begin
  // Separating license data from the main configuration to keep it more hidden
  ConfigFile := TAppConfig.Instance.AppPath + 'license.dat';
  SavedKey := '';

  if FileExists(ConfigFile) then
  begin
    with TStringList.Create do
    try
      LoadFromFile(ConfigFile);
      if Count > 0 then SavedKey := Strings[0];
      if Count > 1 then FTrialEmailsSent := StrToIntDef(Strings[1], 0);
    finally
      Free;
    end;

    // Perform hash verification when the application is opened
    if SavedKey <> '' then
      FIsRegistered := ActivateLicense(SavedKey);
  end;
end;

function TLicenseManager.ActivateLicense(const AKey: string): Boolean;
var
  ExpectedKey: string;
  ConfigFile: string;
begin
  // Lightweight and professional license logic:
  // A valid key is the MD5 Hash result of the combined HWID and secret Salt text.
  ExpectedKey := MD5Print(MD5String(FHardwareID + LICENSE_SALT));

  // SameText ensures there are no issues with uppercase/lowercase letters
  Result := SameText(AKey, ExpectedKey);

  FLock.Acquire;
  try
    FIsRegistered := Result;
    if FIsRegistered then
    begin
      ConfigFile := TAppConfig.Instance.AppPath + 'license.dat';
      with TStringList.Create do
      try
        Add(AKey);
        Add(IntToStr(FTrialEmailsSent));
        SaveToFile(ConfigFile);
      finally
        Free;
      end;
      TLogger.Instance.Log('License successfully activated.', llInfo);
    end;
  finally
    FLock.Release;
  end;
end;

function TLicenseManager.CanSendEmail: Boolean;
begin
  FLock.Acquire;
  try
    if FIsRegistered then
      Result := True
    else
      Result := (FTrialEmailsSent < TRIAL_MAX_EMAILS); // Limit of 5,000 for Trial
  finally
    FLock.Release;
  end;
end;

procedure TLicenseManager.RecordEmailSent;
var
  ConfigFile: string;
begin
  // Bypass logic entirely if the application is registered (saves CPU & I/O cycles)
  if FIsRegistered then Exit;

  FLock.Acquire;
  try
    Inc(FTrialEmailsSent);

    // Extreme Optimization: Save data to Disk I/O ONLY every 50 emails.
    // Saving to the .dat file every 1 email will dramatically slow down sending.
    if (FTrialEmailsSent mod 50 = 0) then
    begin
      ConfigFile := TAppConfig.Instance.AppPath + 'license.dat';
      with TStringList.Create do
      try
        Add(''); // Empty the first line (since there is no valid license)
        Add(IntToStr(FTrialEmailsSent));
        SaveToFile(ConfigFile);
      finally
        Free;
      end;
    end;
  finally
    FLock.Release;
  end;
end;

initialization
  TLicenseManager.FInstance := nil;

finalization
  if Assigned(TLicenseManager.FInstance) then
    TLicenseManager.FInstance.Free;

end.
