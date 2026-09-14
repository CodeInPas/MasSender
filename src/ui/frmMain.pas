unit frmMain;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  uDbConnection, uLicenseManager, uLogger, uBounceProcessor, uSmtpRepo,
  // Importing all sub-forms so they can be embedded
  frmDashboard, frmContacts, frmCampaigns, frmSettings;

type

  { TfrmMainForm }

  TfrmMainForm = class(TForm)
    btnMenuDashboard: TButton;
    btnMenuContacts: TButton;
    btnMenuCampaigns: TButton;
    btnMenuSettings: TButton;
    btnRegister: TButton;
    btnExit: TButton;
    Image1: TImage;
    lblAppTitle: TLabel;
    pnlSidebar: TPanel;
    pnlHost: TPanel;
    procedure btnExitClick(Sender: TObject);
    procedure btnMenuCampaignsClick(Sender: TObject);
    procedure btnMenuContactsClick(Sender: TObject);
    procedure btnMenuDashboardClick(Sender: TObject);
    procedure btnMenuSettingsClick(Sender: TObject);
    procedure btnRegisterClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FBounceProcessor: TBounceProcessor;

    // Instance variables to hold sub-forms
    FDashboardForm: TfrmDashboardForm;
    FContactsForm: TfrmContactsForm;
    FCampaignsForm: TfrmCampaignsForm;
    FSettingsForm: TfrmSettingsForm;

    procedure InitializeSystem;
    procedure StartBackgroundDaemons;

    // Magic function to embed child forms into pnlHost
    procedure EmbedForm(var AFormVar; AFormClass: TFormClass);
    procedure HideAllForms;
    procedure UpdateLicenseUI;
  public

  end;

var
  frmMainForm: TfrmMainForm;

implementation

{$R *.lfm}

{ TfrmMainForm }

procedure TfrmMainForm.FormCreate(Sender: TObject);
begin
  InitializeSystem;
  UpdateLicenseUI;
  StartBackgroundDaemons;

  // Open Dashboard by default when the application is launched
  btnMenuDashboardClick(Self);
end;

procedure TfrmMainForm.FormDestroy(Sender: TObject);
begin
  // Shut down Daemon gracefully when application is closed
  if Assigned(FBounceProcessor) then
  begin
    FBounceProcessor.Terminate;
    FBounceProcessor := nil;
  end;
  TLogger.Instance.Log('Application closed safely.', llInfo);
end;

procedure TfrmMainForm.FormShow(Sender: TObject);
begin
   EmbedForm(FDashboardForm, TfrmDashboardForm);
end;

procedure TfrmMainForm.InitializeSystem;
begin
  // 1. Call DbManager to ensure database and tables are created
  // (Singleton will automatically run the schema upon first access)
  TDbManager.Instance;

  TLogger.Instance.Log('Main application (GUI) launched.', llInfo);
end;

procedure TfrmMainForm.StartBackgroundDaemons;
var
  Profiles: TSmtpProfileArray;
begin
  // Start the IMAP Bounce Processor Daemon.
  // The daemon will read the first Active SMTP profile. In a real enterprise application,
  // you could run multiple TBounceProcessors simultaneously using an array loop.
  Profiles := TSmtpRepo.GetAll(True);
  if Length(Profiles) > 0 then
  begin
    // Initialize interval to 1800 seconds (30 minutes) per IMAP check
    FBounceProcessor := TBounceProcessor.Create(Profiles[0], 1800);
  end
  else
  begin
    TLogger.Instance.Log('No active SMTP profiles found. IMAP Bounce Processor will not be started.', llWarning);
  end;
end;

procedure TfrmMainForm.UpdateLicenseUI;
begin
  if TLicenseManager.Instance.IsRegistered then
  begin
    Self.Caption := 'BulkEmailer Pro - Enterprise Edition (REGISTERED)';
    btnRegister.Visible := False; // Hide activation button if already valid
  end
  else
  begin
    Self.Caption := 'BulkEmailer Pro - TRIAL MODE (Limit: ' + IntToStr(TRIAL_MAX_EMAILS) + ' Emails)';
    btnRegister.Visible := True;
  end;
end;

// ==============================================================================
// NAVIGATION SYSTEM (EMBEDDING FORM)
// ==============================================================================

procedure TfrmMainForm.HideAllForms;
begin
  if Assigned(FDashboardForm) then FDashboardForm.Hide;
  if Assigned(FContactsForm) then FContactsForm.Hide;
  if Assigned(FCampaignsForm) then FCampaignsForm.Hide;
  if Assigned(FSettingsForm) then FSettingsForm.Hide;
end;

procedure TfrmMainForm.EmbedForm(var AFormVar; AFormClass: TFormClass);
var
  TargetForm: TForm absolute AFormVar;
begin
  // Hide other forms so they don't overlap
  HideAllForms;

  // Lazy Loading Pattern: Sub-forms are only created in RAM if the menu is clicked.
  // This saves memory when the user doesn't open a specific menu.
  if not Assigned(TargetForm) then
  begin
    // Create using Self (frmMain) as owner,
    // so memory is automatically cleaned up when frmMain is closed.
    TargetForm := AFormClass.Create(Self);

    // Trick to turn a Window into a Panel
    TargetForm.BorderStyle := bsNone;
    TargetForm.Parent := pnlHost;
    TargetForm.Align := alClient;
  end;

  TargetForm.Show;
end;

procedure TfrmMainForm.btnMenuDashboardClick(Sender: TObject);
begin
  EmbedForm(FDashboardForm, TfrmDashboardForm);
end;

procedure TfrmMainForm.btnMenuContactsClick(Sender: TObject);
begin
  EmbedForm(FContactsForm, TfrmContactsForm);
end;

procedure TfrmMainForm.btnMenuCampaignsClick(Sender: TObject);
begin
  EmbedForm(FCampaignsForm, TfrmCampaignsForm);
end;

procedure TfrmMainForm.btnMenuSettingsClick(Sender: TObject);
begin
  EmbedForm(FSettingsForm, TfrmSettingsForm);
end;

// ==============================================================================
// ADDITIONAL ACTIONS
// ==============================================================================

procedure TfrmMainForm.btnRegisterClick(Sender: TObject);
var
  InputKey: string;
begin
  // Show Hardware ID to the client so they can provide it to you
  // to generate a valid License Key.
  ShowMessage('Your Computer Hardware ID: ' + TLicenseManager.Instance.HardwareID +
              sLineBreak + 'Provide this ID to the Developer to obtain a License Key.');

  if InputQuery('Software Activation', 'Enter License Key (MD5 Hash):', InputKey) then
  begin
    if TLicenseManager.Instance.ActivateLicense(InputKey) then
    begin
      ShowMessage('Thank You! The application has been permanently activated.');
      UpdateLicenseUI;
    end
    else
    begin
      ShowMessage('Invalid License Key or it does not match the Hardware ID of this computer.');
    end;
  end;
end;

procedure TfrmMainForm.btnExitClick(Sender: TObject);
begin
  Close; // Will trigger FormDestroy and safely clean up all systems
end;

end.
