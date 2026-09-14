unit frmDashboard;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  uCampaignRepo, uSmtpRepo, uContactRepo, uSmtpDispatcher, uAnalyticsClient,
  uDnsChecker, uLicenseManager, uLogger, uAppConfig;

type

  { TfrmDashboardForm }

  TfrmDashboardForm = class(TForm)
    btnStart: TButton;
    btnStop: TButton;
    btnDnsCheck: TButton;
    cbCampaigns: TComboBox;
    gbLocalStats: TGroupBox;
    gbRemoteStats: TGroupBox;
    Label1: TLabel;
    lblOpens: TLabel;
    lblClicks: TLabel;
    lblUnsubs: TLabel;
    lblSent: TLabel;
    lblQueued: TLabel;
    lblBounced: TLabel;
    lblSystemStatus: TLabel;
    pnlControl: TPanel;
    pnlStatus: TPanel;
    tmrSync: TTimer;
    procedure btnDnsCheckClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tmrSyncTimer(Sender: TObject);
  private
    FDispatcher: TSmtpDispatcher;
    FCampaignsList: TCampaignArray;
    FApiPollCounter: Integer;

    procedure LoadCampaigns;
    procedure UpdateUIState(AIsRunning: Boolean);
    procedure RefreshLocalStats;
    procedure RefreshRemoteStats(ACampaignID: Integer);
    function GetSelectedCampaignID: Integer;

    procedure OnDispatcherTerminated(Sender: TObject);
  protected
    // FIX: Override DoShow so the form always refreshes data when opened/displayed
    procedure DoShow; override;
  public

  end;

var
  frmDashboardForm: TfrmDashboardForm;

implementation

{$R *.lfm}

{ TfrmDashboardForm }

procedure TfrmDashboardForm.FormCreate(Sender: TObject);
begin
  FDispatcher := nil;
  FApiPollCounter := 0;

  // Ensure the license is checked when the Dashboard is opened
  if not TLicenseManager.Instance.IsRegistered then
    Self.Caption := Self.Caption + ' [TRIAL VERSION - Maximum ' + IntToStr(TRIAL_MAX_EMAILS) + ' Emails]';
end;

// FIX: This procedure will be executed automatically every time the Dashboard form is visible on the screen
procedure TfrmDashboardForm.DoShow;
begin
  inherited DoShow;

  // Refresh data in real-time every time the user switches to this form
  LoadCampaigns;
  RefreshLocalStats;
end;

procedure TfrmDashboardForm.FormDestroy(Sender: TObject);
begin
  if Assigned(FDispatcher) then
    FDispatcher.Terminate;
end;

procedure TfrmDashboardForm.LoadCampaigns;
var
  i: Integer;
  LastSelectedIndex: Integer;
begin
  // Save the currently selected index so it doesn't reset upon refresh
  LastSelectedIndex := cbCampaigns.ItemIndex;

  cbCampaigns.Items.Clear;
  FCampaignsList := TCampaignRepo.GetAll;

  for i := 0 to High(FCampaignsList) do
  begin
    cbCampaigns.Items.AddObject(FCampaignsList[i].Name, TObject(PtrInt(FCampaignsList[i].ID)));
  end;

  if cbCampaigns.Items.Count > 0 then
  begin
    if (LastSelectedIndex >= 0) and (LastSelectedIndex < cbCampaigns.Items.Count) then
      cbCampaigns.ItemIndex := LastSelectedIndex
    else
      cbCampaigns.ItemIndex := 0;
  end;
end;

function TfrmDashboardForm.GetSelectedCampaignID: Integer;
begin
  Result := 0;
  if cbCampaigns.ItemIndex >= 0 then
    Result := Integer(PtrInt(cbCampaigns.Items.Objects[cbCampaigns.ItemIndex]));
end;

procedure TfrmDashboardForm.UpdateUIState(AIsRunning: Boolean);
begin
  btnStart.Enabled := not AIsRunning;
  cbCampaigns.Enabled := not AIsRunning;
  btnDnsCheck.Enabled := not AIsRunning;

  btnStop.Enabled := AIsRunning;
  tmrSync.Enabled := AIsRunning;

  if AIsRunning then
  begin
    lblSystemStatus.Caption := 'System Status: Engine SENDING...';
    pnlStatus.Color := clMoneyGreen;
  end
  else
  begin
    lblSystemStatus.Caption := 'System Status: Engine STOPPED/IDLE.';
    pnlStatus.Color := clInfoBk;
  end;
end;

procedure TfrmDashboardForm.OnDispatcherTerminated(Sender: TObject);
begin
  FDispatcher := nil;
  UpdateUIState(False);
  RefreshLocalStats;
end;

procedure TfrmDashboardForm.btnStartClick(Sender: TObject);
var
  CampID: Integer;
  CbReason: string;
begin
  CampID := GetSelectedCampaignID;
  if CampID = 0 then
  begin
    ShowMessage('Please select a Campaign first.');
    Exit;
  end;

  if not TLicenseManager.Instance.CanSendEmail then
  begin
    ShowMessage('Trial version sending limit has been reached. Please purchase a Full License.');
    Exit;
  end;

  if TContactRepo.GetCountByStatus('Active') = 0 then
  begin
    ShowMessage('No contacts with Active status in the database (queue is empty).');
    Exit;
  end;

  if TSmtpRepo.IsCircuitBreakerTripped(
       TAppConfig.Instance.CbMinHealthScore,
       TAppConfig.Instance.CbMaxBounceRate,
       TAppConfig.Instance.CbTimeWindowMin,
       CbReason) then
  begin
    if MessageDlg('⚠️ Circuit Breaker Warning',
                  'The system detected a security issue with the SMTP:' + sLineBreak +
                  CbReason + sLineBreak + sLineBreak +
                  'Are you sure you want to force the campaign to run (Force Resume)?',
                  mtWarning, [mbYes, mbNo], 0) = mrNo then
    begin
      Exit;
    end;
  end;

  if Assigned(FDispatcher) then
  begin
    FDispatcher.Terminate;
    FDispatcher := nil;
  end;

  FDispatcher := TSmtpDispatcher.Create(CampID, 50);
  FDispatcher.OnTerminate := @OnDispatcherTerminated;

  UpdateUIState(True);
  TLogger.Instance.Log('Campaign started via Dashboard.', llInfo);
end;

procedure TfrmDashboardForm.btnStopClick(Sender: TObject);
begin
  if Assigned(FDispatcher) then
  begin
    FDispatcher.Terminate;
    lblSystemStatus.Caption := 'System Status: Engine WAITING FOR WORKERS TO FINISH...';
    btnStop.Enabled := False;
  end;

  TLogger.Instance.Log('Campaign stop signal sent by the user.', llWarning);
end;

procedure TfrmDashboardForm.btnDnsCheckClick(Sender: TObject);
var
  Profiles: TSmtpProfileArray;
  DomainExtract: string;
begin
  Profiles := TSmtpRepo.GetAll(True);
  if Length(Profiles) = 0 then
  begin
    ShowMessage('No active SMTP Profiles found. Please add them in Settings.');
    Exit;
  end;

  DomainExtract := Profiles[0].Username;
  if Pos('@', DomainExtract) > 0 then
  begin
    DomainExtract := Copy(DomainExtract, Pos('@', DomainExtract) + 1, Length(DomainExtract));

    Screen.Cursor := crHourGlass;
    try
      if TDnsChecker.ValidateDomainHealth(DomainExtract) then
        ShowMessage('DNS Health Check PASSED!' + sLineBreak + 'Domain ' + DomainExtract + ' has valid SPF and DMARC.')
      else
        ShowMessage('⚠️ DNS Health Check FAILED!' + sLineBreak + 'SPF or DMARC issue detected. Very high risk of entering SPAM.');
    finally
      Screen.Cursor := crDefault;
    end;
  end
  else
    ShowMessage('SMTP Username does not contain an email format (domain not detected).');
end;

procedure TfrmDashboardForm.tmrSyncTimer(Sender: TObject);
begin
  RefreshLocalStats;
  Inc(FApiPollCounter);
  if FApiPollCounter >= 5 then
  begin
    FApiPollCounter := 0;
    RefreshRemoteStats(GetSelectedCampaignID);
  end;
end;

procedure TfrmDashboardForm.RefreshLocalStats;
begin
  lblSent.Caption := 'Sent: ' + IntToStr(TContactRepo.GetCountByStatus('Sent'));
  lblQueued.Caption := 'Queued: ' + IntToStr(TContactRepo.GetCountByStatus('Queued'));
  lblBounced.Caption := 'Bounced: ' + IntToStr(TContactRepo.GetCountByStatus('Bounced'));
end;

procedure TfrmDashboardForm.RefreshRemoteStats(ACampaignID: Integer);
var
  Stats: TCampaignStats;
begin
  if ACampaignID = 0 then Exit;

  Stats := TAnalyticsClient.FetchStats(ACampaignID);

  if Stats.IsSuccess then
  begin
    lblOpens.Caption := 'Opens: ' + IntToStr(Stats.Opens);
    lblClicks.Caption := 'Clicks: ' + IntToStr(Stats.Clicks);
    lblUnsubs.Caption := 'Unsubs: ' + IntToStr(Stats.Unsubscribes);
  end;
end;

end.
