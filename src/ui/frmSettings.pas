unit frmSettings;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Spin, Grids,
  uAppConfig, uSmtpRepo;

type

  { TfrmSettingsForm }

  TfrmSettingsForm = class(TForm)
    btnAddSmtp: TButton;
    btnDeleteSmtp: TButton;
    btnSaveAppConfig: TButton;
    btnSaveSmtp: TButton;
    chkActive: TCheckBox;
    chkWarmup: TCheckBox;
    edtPass: TEdit;
    edtHost: TEdit;
    edtTrackingUrl: TEdit;
    edtUser: TEdit;
    gbAppConfig: TGroupBox;
    gbSmtpList: TGroupBox;
    gbSmtpEditor: TGroupBox;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    Label7: TLabel;
    Label8: TLabel;
    LabelWarmupInfo: TLabel;
    seMaxThreads: TSpinEdit;
    seLimit: TSpinEdit;
    seDelay: TSpinEdit;
    sePort: TSpinEdit;
    sgSmtp: TStringGrid;
    procedure btnAddSmtpClick(Sender: TObject);
    procedure btnDeleteSmtpClick(Sender: TObject);
    procedure btnSaveAppConfigClick(Sender: TObject);
    procedure btnSaveSmtpClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure sgSmtpClick(Sender: TObject);
  private
    FCurrentSmtpID: Integer;
    procedure LoadAppConfig;
    procedure LoadSmtpList;
    procedure ClearSmtpEditor;
  protected
    // FIX: Override DoShow so the grid is populated ONLY after the UI is ready to be drawn
    procedure DoShow; override;
  public

  end;

var
  frmSettingsForm: TfrmSettingsForm;

implementation

{$R *.lfm}

{ TfrmSettingsForm }

procedure TfrmSettingsForm.FormCreate(Sender: TObject);
begin
  // LoadSmtpList is removed from here because the UI is not ready. We move it to DoShow.
  ClearSmtpEditor;
end;

procedure TfrmSettingsForm.DoShow;
begin
  inherited DoShow;

  // Now it is safe to populate the visual UI components
  LoadAppConfig;
  LoadSmtpList;
end;

procedure TfrmSettingsForm.LoadAppConfig;
begin
  edtTrackingUrl.Text := TAppConfig.Instance.WebTrackingUrl;
  seMaxThreads.Value := TAppConfig.Instance.MaxWorkerThreads;
end;

procedure TfrmSettingsForm.btnSaveAppConfigClick(Sender: TObject);
begin
  TAppConfig.Instance.WebTrackingUrl := Trim(edtTrackingUrl.Text);
  TAppConfig.Instance.MaxWorkerThreads := seMaxThreads.Value;
  TAppConfig.Instance.SaveConfig;
  ShowMessage('Application settings successfully saved.');
end;

procedure TfrmSettingsForm.LoadSmtpList;
var
  Profiles: TSmtpProfileArray;
  i: Integer;
begin
  Profiles := TSmtpRepo.GetAll(False);

  // FIX: Clear the Grid (Prevent Ghost Rows) if Database is empty
  if Length(Profiles) = 0 then
  begin
    sgSmtp.RowCount := 2;
    sgSmtp.Rows[1].Clear;
    Exit;
  end;

  sgSmtp.RowCount := Length(Profiles) + 1;

  for i := 0 to High(Profiles) do
  begin
    sgSmtp.Cells[0, i + 1] := IntToStr(Profiles[i].ID);
    sgSmtp.Cells[1, i + 1] := Profiles[i].Host;
    sgSmtp.Cells[2, i + 1] := Profiles[i].Username;

    if Profiles[i].IsActive then
    begin
      if Profiles[i].IsWarmup then
        sgSmtp.Cells[3, i + 1] := 'Active (Warmup)'
      else
        sgSmtp.Cells[3, i + 1] := 'Active';
    end
    else
      sgSmtp.Cells[3, i + 1] := 'Inactive';
  end;
end;

procedure TfrmSettingsForm.ClearSmtpEditor;
begin
  FCurrentSmtpID := 0;
  edtHost.Clear;
  sePort.Value := 587;
  edtUser.Clear;
  edtPass.Clear;
  seLimit.Value := 500;
  seDelay.Value := 15000;
  chkActive.Checked := True;

  chkWarmup.Checked := False;
  LabelWarmupInfo.Caption := 'Status: -';

  if edtHost.CanFocus then edtHost.SetFocus;
end;

procedure TfrmSettingsForm.btnAddSmtpClick(Sender: TObject);
begin
  ClearSmtpEditor;
end;

procedure TfrmSettingsForm.btnDeleteSmtpClick(Sender: TObject);
var
  SelectedID: Integer;
begin
  if sgSmtp.Row < 1 then Exit;

  SelectedID := StrToIntDef(sgSmtp.Cells[0, sgSmtp.Row], 0);
  if SelectedID > 0 then
  begin
    if MessageDlg('Delete SMTP?', 'Are you sure you want to delete this profile?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      TSmtpRepo.Delete(SelectedID);
      LoadSmtpList;
      ClearSmtpEditor;
    end;
  end;
end;

procedure TfrmSettingsForm.sgSmtpClick(Sender: TObject);
var
  SelectedID: Integer;
  Profile: TSmtpProfile;
begin
  if sgSmtp.Row < 1 then Exit;

  SelectedID := StrToIntDef(sgSmtp.Cells[0, sgSmtp.Row], 0);
  if SelectedID = 0 then Exit;

  Profile := TSmtpRepo.GetByID(SelectedID);

  if Profile.ID > 0 then
  begin
    FCurrentSmtpID := Profile.ID;
    edtHost.Text := Profile.Host;
    sePort.Value := Profile.Port;
    edtUser.Text := Profile.Username;
    edtPass.Text := Profile.Password;
    seLimit.Value := Profile.DailyLimit;
    seDelay.Value := Profile.DelayMS;
    chkActive.Checked := Profile.IsActive;

    chkWarmup.Checked := Profile.IsWarmup;
    if Profile.IsWarmup then
      LabelWarmupInfo.Caption := Format('Progress: Day %d (%d sent today)', [Profile.WarmupDay, Profile.WarmupSentToday])
    else
      LabelWarmupInfo.Caption := 'Status: Warm-Up Inactive';
  end;
end;

procedure TfrmSettingsForm.btnSaveSmtpClick(Sender: TObject);
var
  Profile: TSmtpProfile;
begin
  if Trim(edtHost.Text) = '' then
  begin
    ShowMessage('Host cannot be empty!');
    Exit;
  end;

  Profile.ID := FCurrentSmtpID;
  Profile.Host := Trim(edtHost.Text);
  Profile.Port := sePort.Value;
  Profile.Username := Trim(edtUser.Text);
  Profile.Password := edtPass.Text;
  Profile.DailyLimit := seLimit.Value;
  Profile.DelayMS := seDelay.Value;
  Profile.IsActive := chkActive.Checked;
  Profile.HealthScore := 100;

  Profile.IsWarmup := chkWarmup.Checked;

  // FIX: Added save success validation
  if TSmtpRepo.Save(Profile) > 0 then
  begin
    ClearSmtpEditor;
    LoadSmtpList;
    ShowMessage('SMTP Profile successfully saved.');
  end
  else
  begin
    ShowMessage('Failed to save SMTP Profile.');
  end;
end;

end.
