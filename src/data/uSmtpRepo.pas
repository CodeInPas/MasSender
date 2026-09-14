unit uSmtpRepo;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, uDbConnection, uLogger;

type
  // TSmtpProfile: Stores credentials and sending limit/delay rules
  TSmtpProfile = record
    ID: Integer;
    Host: string;
    Port: Integer;
    Username: string;
    Password: string;
    DailyLimit: Integer;
    DelayMS: Integer;      // Delay in milliseconds (Throttling)
    HealthScore: Integer;  // Quality indicator (0-100)
    IsActive: Boolean;

    // Additional Feature: Automatic SMTP Warm-Up
    IsWarmup: Boolean;
    WarmupDay: Integer;
    WarmupSentToday: Integer;
    LastSendDate: string;
  end;
  TSmtpProfileArray = array of TSmtpProfile;

  { TSmtpRepo }
  TSmtpRepo = class
  public
    class function GetAll(const AOnlyActive: Boolean = False): TSmtpProfileArray;
    class function GetByID(const AID: Integer): TSmtpProfile;
    class function Save(const AProfile: TSmtpProfile): Integer;
    class procedure Delete(const AID: Integer);
    class procedure UpdateHealthScore(const AID: Integer; const AScoreDelta: Integer);
    class procedure RecordSmtpUsage(const AID: Integer);
    class function IsCircuitBreakerTripped(const AMinHealth, AMaxBounceRate, ATimeWindowMin: Integer; out AReason: string): Boolean;
  end;

implementation

{ TSmtpRepo }

class function TSmtpRepo.GetAll(const AOnlyActive: Boolean): TSmtpProfileArray;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  Idx: Integer;
begin
  SetLength(Result, 0);
  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      if AOnlyActive then
        Qry.SQL.Text := 'SELECT * FROM smtp_profiles WHERE is_active = 1 AND health_score > 0 ORDER BY id ASC'
      else
        Qry.SQL.Text := 'SELECT * FROM smtp_profiles ORDER BY id ASC';

      Qry.Open;

      Idx := 0;
      // FIX: Use Dynamic Arrays (No longer relies on Qry.RecordCount)
      while not Qry.EOF do
      begin
        if Idx >= Length(Result) then
          SetLength(Result, Length(Result) + 20); // Gradual allocation

        Result[Idx].ID := Qry.FieldByName('id').AsInteger;
        Result[Idx].Host := Qry.FieldByName('host').AsString;
        Result[Idx].Port := Qry.FieldByName('port').AsInteger;
        Result[Idx].Username := Qry.FieldByName('username').AsString;
        Result[Idx].Password := Qry.FieldByName('password').AsString;
        Result[Idx].DailyLimit := Qry.FieldByName('daily_limit').AsInteger;
        Result[Idx].DelayMS := Qry.FieldByName('delay_ms').AsInteger;
        Result[Idx].HealthScore := Qry.FieldByName('health_score').AsInteger;
        Result[Idx].IsActive := Qry.FieldByName('is_active').AsInteger = 1;

        Result[Idx].IsWarmup := Qry.FieldByName('is_warmup').AsInteger = 1;
        Result[Idx].WarmupDay := Qry.FieldByName('warmup_day').AsInteger;
        Result[Idx].WarmupSentToday := Qry.FieldByName('warmup_sent_today').AsInteger;
        Result[Idx].LastSendDate := Qry.FieldByName('last_send_date').AsString;

        Inc(Idx);
        Qry.Next;
      end;

      // Trim unused memory
      SetLength(Result, Idx);
    except
      on E: Exception do
        TLogger.Instance.Log('TSmtpRepo.GetAll Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TSmtpRepo.GetByID(const AID: Integer): TSmtpProfile;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  FillByte(Result, SizeOf(TSmtpProfile), 0);

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'SELECT * FROM smtp_profiles WHERE id = :id';
      Qry.ParamByName('id').AsInteger := AID;
      Qry.Open;

      if not Qry.EOF then
      begin
        Result.ID := Qry.FieldByName('id').AsInteger;
        Result.Host := Qry.FieldByName('host').AsString;
        Result.Port := Qry.FieldByName('port').AsInteger;
        Result.Username := Qry.FieldByName('username').AsString;
        Result.Password := Qry.FieldByName('password').AsString;
        Result.DailyLimit := Qry.FieldByName('daily_limit').AsInteger;
        Result.DelayMS := Qry.FieldByName('delay_ms').AsInteger;
        Result.HealthScore := Qry.FieldByName('health_score').AsInteger;
        Result.IsActive := Qry.FieldByName('is_active').AsInteger = 1;

        Result.IsWarmup := Qry.FieldByName('is_warmup').AsInteger = 1;
        Result.WarmupDay := Qry.FieldByName('warmup_day').AsInteger;
        Result.WarmupSentToday := Qry.FieldByName('warmup_sent_today').AsInteger;
        Result.LastSendDate := Qry.FieldByName('last_send_date').AsString;
      end;
    except
      on E: Exception do
        TLogger.Instance.Log('TSmtpRepo.GetByID Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TSmtpRepo.Save(const AProfile: TSmtpProfile): Integer;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  IntIsActive, IntIsWarmup: Integer;
begin
  Result := AProfile.ID;
  if AProfile.IsActive then IntIsActive := 1 else IntIsActive := 0;
  if AProfile.IsWarmup then IntIsWarmup := 1 else IntIsWarmup := 0;

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      if not Trans.Active then
        Trans.StartTransaction;

      if AProfile.ID = 0 then
      begin
        Qry.SQL.Text := 'INSERT INTO smtp_profiles (host, port, username, password, daily_limit, delay_ms, health_score, is_active, ' +
                        'is_warmup, warmup_day, warmup_sent_today, last_send_date) ' +
                        'VALUES (:host, :port, :user, :pass, :limit, :delay, :health, :active, :iswarm, :wday, :wsent, :wlast)';
      end
      else
      begin
        Qry.SQL.Text := 'UPDATE smtp_profiles SET host = :host, port = :port, username = :user, password = :pass, ' +
                        'daily_limit = :limit, delay_ms = :delay, health_score = :health, is_active = :active, ' +
                        'is_warmup = :iswarm, warmup_day = :wday, warmup_sent_today = :wsent, last_send_date = :wlast ' +
                        'WHERE id = :id';
        Qry.ParamByName('id').AsInteger := AProfile.ID;
      end;

      Qry.ParamByName('host').AsString := Trim(AProfile.Host);
      Qry.ParamByName('port').AsInteger := AProfile.Port;
      Qry.ParamByName('user').AsString := Trim(AProfile.Username);
      Qry.ParamByName('pass').AsString := AProfile.Password;
      Qry.ParamByName('limit').AsInteger := AProfile.DailyLimit;
      Qry.ParamByName('delay').AsInteger := AProfile.DelayMS;

      Qry.ParamByName('active').AsInteger := IntIsActive;
      Qry.ParamByName('iswarm').AsInteger := IntIsWarmup;

      if AProfile.ID = 0 then
      begin
        Qry.ParamByName('health').AsInteger := 100;
        Qry.ParamByName('wday').AsInteger := 1;
        Qry.ParamByName('wsent').AsInteger := 0;
        Qry.ParamByName('wlast').AsString := '';
      end
      else
      begin
        Qry.ParamByName('health').AsInteger := AProfile.HealthScore;
        Qry.ParamByName('wday').AsInteger := AProfile.WarmupDay;
        Qry.ParamByName('wsent').AsInteger := AProfile.WarmupSentToday;
        Qry.ParamByName('wlast').AsString := AProfile.LastSendDate;
      end;

      Qry.ExecSQL;

      if AProfile.ID = 0 then
      begin
        Qry.SQL.Text := 'SELECT last_insert_rowid() AS new_id';
        Qry.Open;
        Result := Qry.FieldByName('new_id').AsInteger;
        Qry.Close;
      end;

      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('TSmtpRepo.Save Error: ' + E.Message, llError);
        Result := 0;
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TSmtpRepo.Delete(const AID: Integer);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'DELETE FROM smtp_profiles WHERE id = :id';

      if not Trans.Active then
        Trans.StartTransaction;

      Qry.ParamByName('id').AsInteger := AID;
      Qry.ExecSQL;
      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('TSmtpRepo.Delete Error: ' + E.Message, llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TSmtpRepo.UpdateHealthScore(const AID: Integer; const AScoreDelta: Integer);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  if AScoreDelta = 0 then Exit;

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      if not Trans.Active then
        Trans.StartTransaction;

      Qry.SQL.Text := 'UPDATE smtp_profiles ' +
                      'SET health_score = MAX(0, MIN(100, health_score + :delta)) ' +
                      'WHERE id = :id';
      Qry.ParamByName('delta').AsInteger := AScoreDelta;
      Qry.ParamByName('id').AsInteger := AID;
      Qry.ExecSQL;

      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log(Format('Failed to update SMTP Health Score %d: %s', [AID, E.Message]), llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TSmtpRepo.RecordSmtpUsage(const AID: Integer);
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  TodayStr: string;
begin
  TodayStr := FormatDateTime('yyyy-mm-dd', Now);

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      if not Trans.Active then
        Trans.StartTransaction;

      Qry.SQL.Text :=
        'UPDATE smtp_profiles SET ' +
        '  warmup_day = CASE WHEN last_send_date <> :today AND is_warmup = 1 AND last_send_date IS NOT NULL AND last_send_date <> '''' THEN warmup_day + 1 ELSE warmup_day END, ' +
        '  warmup_sent_today = CASE WHEN last_send_date <> :today THEN 1 ELSE warmup_sent_today + 1 END, ' +
        '  last_send_date = :today ' +
        'WHERE id = :id';

      Qry.ParamByName('today').AsString := TodayStr;
      Qry.ParamByName('id').AsInteger := AID;
      Qry.ExecSQL;

      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log(Format('Failed to record Smtp Usage for Profile %d: %s', [AID, E.Message]), llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TSmtpRepo.IsCircuitBreakerTripped(const AMinHealth, AMaxBounceRate, ATimeWindowMin: Integer; out AReason: string): Boolean;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
  TotalSent, TotalFailed: Integer;
  BounceRate: Double;
begin
  Result := False;
  AReason := '';
  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      // 1. Check the Health Score of Active SMTPs
      Qry.SQL.Text := 'SELECT host, health_score FROM smtp_profiles WHERE is_active = 1 AND health_score < :min_health LIMIT 1';
      Qry.ParamByName('min_health').AsInteger := AMinHealth;
      Qry.Open;
      if not Qry.EOF then
      begin
        AReason := Format('SMTP health score [%s] dropped to %d (Minimum limit: %d).',
                          [Qry.FieldByName('host').AsString, Qry.FieldByName('health_score').AsInteger, AMinHealth]);
        Result := True;
        Exit;
      end;
      Qry.Close;

      // 2. Check Bounce/Failed Ratio within the Time Window
      // FIX: Use IFNULL() so SUM() yields 0 (not NULL/Empty) when the log is still empty.
      Qry.SQL.Text :=
        'SELECT ' +
        '  COUNT(*) AS total_sends, ' +
        '  IFNULL(SUM(CASE WHEN status IN (''Failed'', ''Bounced'') THEN 1 ELSE 0 END), 0) AS total_fails ' +
        'FROM send_logs ' +
        'WHERE sent_at >= datetime(''now'', :time_window)';

      Qry.ParamByName('time_window').AsString := '-' + IntToStr(ATimeWindowMin) + ' minutes';
      Qry.Open;

      if not Qry.EOF then
      begin
        TotalSent := Qry.FieldByName('total_sends').AsInteger;

        // FIX: Double safeguard on the Lazarus side to prevent EConvertError
        if Qry.FieldByName('total_fails').IsNull then
          TotalFailed := 0
        else
          TotalFailed := Qry.FieldByName('total_fails').AsInteger;

        // Circuit Breaker only evaluates if the sending sample has reached 10 emails
        if TotalSent >= 10 then
        begin
          BounceRate := (TotalFailed / TotalSent) * 100;
          if BounceRate >= AMaxBounceRate then
          begin
            AReason := Format('Bounce/Failed ratio spiked to %.1f%% in the last %d minutes (Limit: %d%%).',
                              [BounceRate, ATimeWindowMin, AMaxBounceRate]);
            Result := True;
            Exit;
          end;
        end;
      end;

    except
      on E: Exception do
        TLogger.Instance.Log('Circuit Breaker Check Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

end.
