unit frmContacts;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  Grids, StrUtils, uContactRepo, uLogger;

type

  { TfrmContactsForm }

  TfrmContactsForm = class(TForm)
    btnImportCSV: TButton;
    btnManualOptOut: TButton;
    btnRefresh: TButton;
    btnCancelQueue: TButton;
    dlgOpenCSV: TOpenDialog;
    gbPreview: TGroupBox;
    lblTotal: TLabel;
    lblActive: TLabel;
    lblBounced: TLabel;
    lblUnsubscribed: TLabel;
    lblQueued: TLabel;
    pnlTop: TPanel;
    pnlBottom: TPanel;
    sgContacts: TStringGrid;
    procedure btnImportCSVClick(Sender: TObject);
    procedure btnManualOptOutClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnCancelQueueClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    procedure RefreshDashboard;
    procedure LoadPreviewGrid;
    function SplitCsvLine(const ALine: string; out AEmail, AName: string): Boolean;
  protected
    // FIX: Override DoShow to load data after the form is ready to be drawn
    procedure DoShow; override;
  public

  end;

var
  frmContactsForm: TfrmContactsForm;

implementation

{$R *.lfm}

{ TfrmContactsForm }

procedure TfrmContactsForm.FormCreate(Sender: TObject);
begin
  // Logic moved to DoShow
end;

procedure TfrmContactsForm.DoShow;
begin
  inherited DoShow;

  // Refresh UI after form is ready
  RefreshDashboard;
  LoadPreviewGrid;
end;

procedure TfrmContactsForm.btnRefreshClick(Sender: TObject);
begin
  RefreshDashboard;
  LoadPreviewGrid;
end;

procedure TfrmContactsForm.btnCancelQueueClick(Sender: TObject);
begin
  // Security validation to prevent accidental clicks
  if MessageDlg('Cancel Queue?',
                'Are you sure you want to cancel all emails with Active (Ready to Send) status? ' + sLineBreak +
                'Their status will be changed to Cancelled and the sending engine will ignore them.',
                mtWarning, [mbYes, mbNo], 0) = mrYes then
  begin
    Screen.Cursor := crHourGlass;
    try
      // Call repository to execute mass cancellation
      TContactRepo.CancelAllActiveQueue;

      // Refresh UI display
      RefreshDashboard;
      LoadPreviewGrid;

      ShowMessage('All sending queues have been successfully cancelled!');
    finally
      Screen.Cursor := crDefault;
    end;
  end;
end;

procedure TfrmContactsForm.RefreshDashboard;
var
  TotalActive, TotalBounced, TotalUnsubscribed, TotalQueued, TotalAll: Integer;
begin
  TotalActive := TContactRepo.GetCountByStatus('Active');
  TotalBounced := TContactRepo.GetCountByStatus('Bounced');
  TotalUnsubscribed := TContactRepo.GetCountByStatus('Unsubscribed');
  TotalQueued := TContactRepo.GetCountByStatus('Queued');

  TotalAll := TotalActive + TotalBounced + TotalUnsubscribed + TotalQueued;

  lblTotal.Caption := Format('Total Contacts: %d', [TotalAll]);
  lblActive.Caption := Format('Active (Ready): %d', [TotalActive]);
  lblBounced.Caption := Format('Bounced: %d', [TotalBounced]);
  lblUnsubscribed.Caption := Format('Unsubscribed: %d', [TotalUnsubscribed]);
  lblQueued.Caption := Format('Queued: %d', [TotalQueued]);
end;

procedure TfrmContactsForm.LoadPreviewGrid;
var
  PreviewContacts: TContactArray;
  i: Integer;
begin
  PreviewContacts := TContactRepo.GetPreviewContacts(100);

  if Length(PreviewContacts) = 0 then
  begin
    sgContacts.RowCount := 2;
    sgContacts.Rows[1].Clear;
    Exit;
  end;

  sgContacts.RowCount := Length(PreviewContacts) + 1;

  for i := 0 to High(PreviewContacts) do
  begin
    sgContacts.Cells[0, i + 1] := IntToStr(PreviewContacts[i].ID);
    sgContacts.Cells[1, i + 1] := PreviewContacts[i].Email;
    sgContacts.Cells[2, i + 1] := PreviewContacts[i].Name;
    sgContacts.Cells[3, i + 1] := PreviewContacts[i].Status;
  end;
end;

function TfrmContactsForm.SplitCsvLine(const ALine: string; out AEmail, AName: string): Boolean;
var
  Parts: TStringArray;
begin
  Result := False;
  AEmail := '';
  AName := '';

  if Trim(ALine) = '' then Exit;

  Parts := SplitString(ALine, ',');

  if Length(Parts) > 0 then
  begin
    AEmail := Trim(Parts[0]);
    if Length(Parts) > 1 then
      AName := Trim(Parts[1]);

    if Pos('@', AEmail) > 0 then Result := True;
  end;
end;

procedure TfrmContactsForm.btnImportCSVClick(Sender: TObject);
var
  CsvLines: TStringList;
  NewContacts: TContactArray;
  i, ValidCount: Integer;
  ParsedEmail, ParsedName: string;
begin
  if not dlgOpenCSV.Execute then Exit;

  Screen.Cursor := crHourGlass;
  CsvLines := TStringList.Create;
  try
    try
      CsvLines.LoadFromFile(dlgOpenCSV.FileName);
      SetLength(NewContacts, CsvLines.Count);
      ValidCount := 0;

      for i := 0 to CsvLines.Count - 1 do
      begin
        if (i = 0) and (Pos('email', LowerCase(CsvLines[i])) > 0) then Continue;

        if SplitCsvLine(CsvLines[i], ParsedEmail, ParsedName) then
        begin
          NewContacts[ValidCount].Email := ParsedEmail;
          NewContacts[ValidCount].Name := ParsedName;
          Inc(ValidCount);
        end;
      end;

      SetLength(NewContacts, ValidCount);

      if ValidCount > 0 then
      begin
        TContactRepo.BulkInsert(NewContacts);
        ShowMessage(Format('Successfully loaded %d contacts into the queue (Duplicates automatically ignored).', [ValidCount]));
        RefreshDashboard;
        LoadPreviewGrid;
      end
      else
      begin
        ShowMessage('No valid emails found in the CSV file.');
      end;

    except
      on E: Exception do
      begin
        TLogger.Instance.Log('Failed to load CSV: ' + E.Message, llError);
        ShowMessage('An error occurred while loading the CSV. Make sure the file is not currently open in Excel.');
      end;
    end;
  finally
    CsvLines.Free;
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmContactsForm.btnManualOptOutClick(Sender: TObject);
var
  InputEmail: string;
begin
  if InputQuery('Manual Suppression', 'Enter the email address you want to blacklist (Unsubscribe):', InputEmail) then
  begin
    InputEmail := Trim(InputEmail);
    if InputEmail <> '' then
    begin
      TContactRepo.UpdateStatus(InputEmail, 'Unsubscribed');
      ShowMessage(InputEmail + ' has been successfully added to the Suppression list.');
      RefreshDashboard;
      LoadPreviewGrid;
    end;
  end;
end;

end.
