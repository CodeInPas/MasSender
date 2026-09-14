unit uSmtpDispatcher;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, syncobjs,
  uSmtpWorker, uContactRepo, uCampaignRepo, uSmtpRepo, uDbConnection, uLogger, uAppConfig;

type
  { TSmtpDispatcher }

  TSmtpDispatcher = class(TThread)
  private
    FCampaignID: Integer;
    FBatchSize: Integer;
    FActiveWorkers: Integer;

    procedure MarkBatchAsQueued(const AContacts: TContactArray);
    procedure ReleaseQueuedBatch(const AContacts: TContactArray);
    procedure OnWorkerFinished(Sender: TObject);
  protected
    procedure Execute; override;
  public
    constructor Create(const ACampaignID: Integer; const ABatchSize: Integer = 50);
  end;

implementation

{ TSmtpDispatcher }

constructor TSmtpDispatcher.Create(const ACampaignID: Integer; const ABatchSize: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := True;

  FCampaignID := ACampaignID;
  FBatchSize := ABatchSize;
  FActiveWorkers := 0;
end;

procedure TSmtpDispatcher.MarkBatchAsQueued(const AContacts: TContactArray);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  i: Integer;
begin
  if Length(AContacts) = 0 then Exit;

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'UPDATE contacts SET status = ''Queued'' WHERE id = :id';
      Qry.Prepare;

      // FIX: SQLDB Transaction Safeguard
      if not Trans.Active then
        Trans.StartTransaction;

      for i := 0 to High(AContacts) do
      begin
        Qry.ParamByName('id').AsInteger := AContacts[i].ID;
        Qry.ExecSQL;
      end;
      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('Dispatcher Error (MarkAsQueued): ' + E.Message, llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

procedure TSmtpDispatcher.ReleaseQueuedBatch(const AContacts: TContactArray);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  i: Integer;
begin
  if Length(AContacts) = 0 then Exit;

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'UPDATE contacts SET status = ''Active'' WHERE id = :id';
      Qry.Prepare;

      // FIX: SQLDB Transaction Safeguard
      if not Trans.Active then
        Trans.StartTransaction;

      for i := 0 to High(AContacts) do
      begin
        Qry.ParamByName('id').AsInteger := AContacts[i].ID;
        Qry.ExecSQL;
      end;
      Trans.Commit;
    except
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

procedure TSmtpDispatcher.OnWorkerFinished(Sender: TObject);
begin
  InterlockedDecrement(FActiveWorkers);
end;

procedure TSmtpDispatcher.Execute;
var
  SmtpProfiles: TSmtpProfileArray;
  Campaign: TCampaign;
  ContactsBatch: TContactArray;
  Worker: TSmtpWorker;
  SmtpIdx: Integer;
  MaxWorkers: Integer;

  Attempts: Integer;
  MaxForToday: Integer;
  RemainingToday: Integer;
  AssignedBatchSize: Integer;
  TodayStr: string;

  CbReason: string;
begin
  TLogger.Instance.Log('Dispatcher: Starting Campaign ID ' + IntToStr(FCampaignID), llInfo);

  Campaign := TCampaignRepo.GetByID(FCampaignID);
  if Campaign.ID = 0 then
  begin
    TLogger.Instance.Log('Dispatcher: Campaign not found. Aborted.', llError);
    Exit;
  end;

  SmtpProfiles := TSmtpRepo.GetAll(True);
  if Length(SmtpProfiles) = 0 then
  begin
    TLogger.Instance.Log('Dispatcher: No ready SMTP profiles found (Active & Health > 0). Aborted.', llError);
    Exit;
  end;

  SmtpIdx := 0;
  MaxWorkers := TAppConfig.Instance.MaxWorkerThreads;

  while not Terminated do
  begin
    while (FActiveWorkers >= MaxWorkers) and (not Terminated) do
      Sleep(200);

    if Terminated then Break;

    if TSmtpRepo.IsCircuitBreakerTripped(
         TAppConfig.Instance.CbMinHealthScore,
         TAppConfig.Instance.CbMaxBounceRate,
         TAppConfig.Instance.CbTimeWindowMin,
         CbReason) then
    begin
      TLogger.Instance.Log('⛔ SMART CIRCUIT BREAKER TRIGGERED! Campaign paused for emergency.', llError);
      TLogger.Instance.Log('Reason: ' + CbReason, llError);
      Break;
    end;

    Attempts := 0;
    AssignedBatchSize := 0;
    TodayStr := FormatDateTime('yyyy-mm-dd', Now);

    while Attempts < Length(SmtpProfiles) do
    begin
      if SmtpProfiles[SmtpIdx].LastSendDate <> TodayStr then
      begin
        if (SmtpProfiles[SmtpIdx].LastSendDate <> '') and (SmtpProfiles[SmtpIdx].IsWarmup) then
          Inc(SmtpProfiles[SmtpIdx].WarmupDay);

        SmtpProfiles[SmtpIdx].WarmupSentToday := 0;
        SmtpProfiles[SmtpIdx].LastSendDate := TodayStr;
      end;

      MaxForToday := SmtpProfiles[SmtpIdx].DailyLimit;
      if SmtpProfiles[SmtpIdx].IsWarmup then
      begin
        MaxForToday := 20 * SmtpProfiles[SmtpIdx].WarmupDay;
        if MaxForToday > SmtpProfiles[SmtpIdx].DailyLimit then
          MaxForToday := SmtpProfiles[SmtpIdx].DailyLimit;
      end;

      RemainingToday := MaxForToday - SmtpProfiles[SmtpIdx].WarmupSentToday;

      if RemainingToday > 0 then
      begin
        if RemainingToday < FBatchSize then
          AssignedBatchSize := RemainingToday
        else
          AssignedBatchSize := FBatchSize;
        Break;
      end;

      SmtpIdx := (SmtpIdx + 1) mod Length(SmtpProfiles);
      Inc(Attempts);
    end;

    if AssignedBatchSize = 0 then
    begin
      TLogger.Instance.Log('Dispatcher: All SMTP profiles have reached their daily limit (Limit/Warm-Up). Campaign paused.', llWarning);
      Break;
    end;

    ContactsBatch := TContactRepo.GetActiveContacts(AssignedBatchSize);

    if Length(ContactsBatch) = 0 then
    begin
      TLogger.Instance.Log('Dispatcher: All contacts successfully dispatched / queue is empty.', llInfo);
      Break;
    end;

    MarkBatchAsQueued(ContactsBatch);

    if Terminated then
    begin
      ReleaseQueuedBatch(ContactsBatch);
      Break;
    end;

    SmtpProfiles[SmtpIdx].WarmupSentToday := SmtpProfiles[SmtpIdx].WarmupSentToday + Length(ContactsBatch);
    InterlockedIncrement(FActiveWorkers);

    Worker := TSmtpWorker.Create(ContactsBatch, Campaign, SmtpProfiles[SmtpIdx]);
    Worker.OnTerminate := @OnWorkerFinished;

    TLogger.Instance.Log(Format('Dispatcher: Launching Worker (SMTP %s) for %d emails. (Warm-Up Mode: %s, Remaining Daily Quota: %d)',
                         [SmtpProfiles[SmtpIdx].Host, Length(ContactsBatch),
                          BoolToStr(SmtpProfiles[SmtpIdx].IsWarmup, 'Active', 'Inactive'),
                          RemainingToday - Length(ContactsBatch)]), llInfo);

    SmtpIdx := (SmtpIdx + 1) mod Length(SmtpProfiles);
  end;

  if Terminated then
    TLogger.Instance.Log('Dispatcher: Forcefully stopped by user.', llWarning)
  else
    TLogger.Instance.Log('Dispatcher: Finished assigning queue (or daily limit reached / CB Active).', llInfo);
end;

end.
