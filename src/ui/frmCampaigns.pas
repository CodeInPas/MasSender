unit frmCampaigns;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Grids,
  uCampaignRepo, uLogger, uAiSpintax;

type

  { TfrmCampaignsForm }

  TfrmCampaignsForm = class(TForm)
    btnAdd: TButton;
    btnDelete: TButton;
    btnSave: TButton;
    btnGenerateAi: TButton;
    edtName: TEdit;
    gbList: TGroupBox;
    gbEditor: TGroupBox;
    Label1: TLabel;
    Label2: TLabel;
    lblHint: TLabel;
    mmoTemplate: TMemo;
    sgCampaigns: TStringGrid;
    procedure btnAddClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure btnGenerateAiClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure sgCampaignsClick(Sender: TObject);
  private
    FCurrentCampaignID: Integer;
    procedure LoadCampaignList;
    procedure ClearEditor;

    procedure OnAiCompleteHandler(const AResult: string);
    procedure OnAiErrorHandler(const AErrorMsg: string);
  protected
    // FIX: Override DoShow
    procedure DoShow; override;
  public

  end;

var
  frmCampaignsForm: TfrmCampaignsForm;

implementation

{$R *.lfm}

{ TfrmCampaignsForm }

procedure TfrmCampaignsForm.FormCreate(Sender: TObject);
begin
  // Cleared, moved to DoShow
end;

procedure TfrmCampaignsForm.DoShow;
begin
  inherited DoShow;

  // Refresh UI after the form is ready to be drawn
  LoadCampaignList;
  ClearEditor;
end;

procedure TfrmCampaignsForm.LoadCampaignList;
var
  Campaigns: TCampaignArray;
  i: Integer;
begin
  Campaigns := TCampaignRepo.GetAll;

  // FIX: Clear the Grid from ghost rows if empty
  if Length(Campaigns) = 0 then
  begin
    sgCampaigns.RowCount := 2;
    sgCampaigns.Rows[1].Clear;
    Exit;
  end;

  sgCampaigns.RowCount := Length(Campaigns) + 1;

  for i := 0 to High(Campaigns) do
  begin
    sgCampaigns.Cells[0, i + 1] := IntToStr(Campaigns[i].ID);
    sgCampaigns.Cells[1, i + 1] := Campaigns[i].Name;
  end;
end;

procedure TfrmCampaignsForm.ClearEditor;
begin
  FCurrentCampaignID := 0;
  edtName.Clear;
  mmoTemplate.Clear;
  if edtName.CanFocus then edtName.SetFocus;
end;

procedure TfrmCampaignsForm.btnAddClick(Sender: TObject);
begin
  ClearEditor;
end;

procedure TfrmCampaignsForm.sgCampaignsClick(Sender: TObject);
var
  SelectedID: Integer;
  Campaign: TCampaign;
begin
  if sgCampaigns.Row < 1 then Exit;

  SelectedID := StrToIntDef(sgCampaigns.Cells[0, sgCampaigns.Row], 0);
  if SelectedID = 0 then Exit;

  Campaign := TCampaignRepo.GetByID(SelectedID);

  if Campaign.ID > 0 then
  begin
    FCurrentCampaignID := Campaign.ID;
    edtName.Text := Campaign.Name;
    mmoTemplate.Text := Campaign.TemplateText;
  end;
end;

procedure TfrmCampaignsForm.btnSaveClick(Sender: TObject);
var
  NewID: Integer;
begin
  if Trim(edtName.Text) = '' then
  begin
    ShowMessage('Campaign Name or Subject cannot be empty.');
    if edtName.CanFocus then edtName.SetFocus;
    Exit;
  end;

  if Trim(mmoTemplate.Text) = '' then
  begin
    ShowMessage('Message content (Template) cannot be empty.');
    if mmoTemplate.CanFocus then mmoTemplate.SetFocus;
    Exit;
  end;

  NewID := TCampaignRepo.Save(edtName.Text, mmoTemplate.Text, FCurrentCampaignID);

  if NewID > 0 then
  begin
    FCurrentCampaignID := NewID;
    LoadCampaignList;
    ShowMessage('Campaign successfully saved.');
  end
  else
  begin
    ShowMessage('Failed to save campaign. Check the application log.');
  end;
end;

procedure TfrmCampaignsForm.btnDeleteClick(Sender: TObject);
var
  SelectedID: Integer;
begin
  if sgCampaigns.Row < 1 then Exit;

  SelectedID := StrToIntDef(sgCampaigns.Cells[0, sgCampaigns.Row], 0);
  if SelectedID > 0 then
  begin
    if MessageDlg('Delete Campaign?',
                  'Are you sure? Deleted campaign data cannot be restored.',
                  mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      TCampaignRepo.Delete(SelectedID);
      LoadCampaignList;
      ClearEditor;
    end;
  end;
end;

// ============================================================================
// AI SPINTAX GENERATOR LOGIC
// ============================================================================

procedure TfrmCampaignsForm.btnGenerateAiClick(Sender: TObject);
var
  AiThread: TAiSpintaxGenerator;
  Endpoint, ApiKey: string;
begin
  if Trim(mmoTemplate.Text) = '' then
  begin
    ShowMessage('Fill in the message template (Text) first as a base reference for the AI.');
    Exit;
  end;

  ApiKey := '';
  if not InputQuery('Google Gemini AI', 'Enter your API Key:', ApiKey) then Exit;
  if Trim(ApiKey) = '' then Exit;

  Endpoint := 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=' + ApiKey;

  Screen.Cursor := crHourGlass;
  mmoTemplate.Enabled := False;
  btnSave.Enabled := False;
  btnGenerateAi.Enabled := False;
  btnGenerateAi.Caption := 'Contacting AI...';

  AiThread := TAiSpintaxGenerator.Create(apGemini, Endpoint, '', mmoTemplate.Text);

  AiThread.OnComplete := @Self.OnAiCompleteHandler;
  AiThread.OnError := @Self.OnAiErrorHandler;

  AiThread.Start;
end;

procedure TfrmCampaignsForm.OnAiCompleteHandler(const AResult: string);
begin
  Screen.Cursor := crDefault;
  mmoTemplate.Enabled := True;
  btnSave.Enabled := True;
  btnGenerateAi.Enabled := True;
  btnGenerateAi.Caption := 'Generate AI Spintax';

  mmoTemplate.Text := AResult;
  ShowMessage('Template successfully reformatted into Spintax format by AI!');
end;

procedure TfrmCampaignsForm.OnAiErrorHandler(const AErrorMsg: string);
begin
  Screen.Cursor := crDefault;
  mmoTemplate.Enabled := True;
  btnSave.Enabled := True;
  btnGenerateAi.Enabled := True;
  btnGenerateAi.Caption := 'Generate AI Spintax';

  ShowMessage('Failed to contact AI Server: ' + AErrorMsg);
end;

end.
