unit uDbConnection;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, uAppConfig, uLogger;

type
  { TDbManager }
  // Acts as the central manager (Singleton) for the SQLite database.
  TDbManager = class
  private
    FDbFilePath: string;
    class var FInstance: TDbManager;

    procedure InitializeDatabase;

    // Smart function to check columns to prevent triggering errors in the Lazarus Debugger
    function ColumnExists(AConn: TSQLite3Connection; ATrans: TSQLTransaction; const ATableName, AColumnName: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    class function Instance: TDbManager;
    function CreateNewConnection(out ATransaction: TSQLTransaction): TSQLite3Connection;
  end;

implementation

{ TDbManager }

constructor TDbManager.Create;
begin
  FDbFilePath := IncludeTrailingPathDelimiter(TAppConfig.Instance.DbPath) + 'mailer_data.db';
  InitializeDatabase;
end;

destructor TDbManager.Destroy;
begin
  inherited Destroy;
end;

class function TDbManager.Instance: TDbManager;
begin
  if not Assigned(FInstance) then
    FInstance := TDbManager.Create;
  Result := FInstance;
end;

function TDbManager.CreateNewConnection(out ATransaction: TSQLTransaction): TSQLite3Connection;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
begin
  Conn := TSQLite3Connection.Create(nil);
  Trans := TSQLTransaction.Create(Conn);

  try
    Conn.DatabaseName := FDbFilePath;
    Trans.DataBase := Conn;
    Conn.Transaction := Trans;
    Conn.CharSet := 'UTF-8';

    ATransaction := Trans;
    Result := Conn;
  except
    on E: Exception do
    begin
      Trans.Free;
      Conn.Free;
      TLogger.Instance.Log('Failed to create database connection: ' + E.Message, llError);
      raise;
    end;
  end;
end;

function TDbManager.ColumnExists(AConn: TSQLite3Connection; ATrans: TSQLTransaction; const ATableName, AColumnName: string): Boolean;
var
  Qry: TSQLQuery;
begin
  Result := False;
  Qry := TSQLQuery.Create(nil);
  try
    Qry.DataBase := AConn;
    Qry.Transaction := ATrans;

    if not ATrans.Active then ATrans.StartTransaction;

    Qry.SQL.Text := 'PRAGMA table_info(' + ATableName + ')';
    Qry.Open;
    while not Qry.EOF do
    begin
      if SameText(Qry.FieldByName('name').AsString, AColumnName) then
      begin
        Result := True;
        Break;
      end;
      Qry.Next;
    end;
    Qry.Close;
  finally
    Qry.Free;
  end;
end;

procedure TDbManager.InitializeDatabase;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
begin
  TLogger.Instance.Log('Checking and initializing database schema...', llInfo);

  Conn := CreateNewConnection(Trans);
  try
    Conn.Open;

    // 1. Execute PRAGMA
   // Conn.ExecuteDirect('PRAGMA journal_mode=WAL;');
    if Trans.Active then Trans.Commit;

    //Conn.ExecuteDirect('PRAGMA synchronous=NORMAL;');
    if Trans.Active then Trans.Commit;

    //Conn.ExecuteDirect('PRAGMA temp_store=MEMORY;');
    if Trans.Active then Trans.Commit;

    // 2. Basic Table Creation
    if not Trans.Active then Trans.StartTransaction;

    Conn.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS contacts (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  email TEXT NOT NULL UNIQUE,' +
      '  name TEXT,' +
      '  status TEXT DEFAULT ''Active''' +
      ');'
    );
    Conn.ExecuteDirect('CREATE INDEX IF NOT EXISTS idx_contacts_status ON contacts(status);');

    Conn.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS campaigns (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  name TEXT NOT NULL,' +
      '  template_text TEXT,' +
      '  created_at DATETIME DEFAULT CURRENT_TIMESTAMP' +
      ');'
    );

    Conn.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS smtp_profiles (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  host TEXT NOT NULL,' +
      '  port INTEGER DEFAULT 587,' +
      '  username TEXT,' +
      '  password TEXT,' +
      '  daily_limit INTEGER DEFAULT 500,' +
      '  delay_ms INTEGER DEFAULT 15000,' +
      '  health_score INTEGER DEFAULT 100,' +
      '  is_active INTEGER DEFAULT 1,' +
      '  is_warmup INTEGER DEFAULT 0,' +
      '  warmup_day INTEGER DEFAULT 1,' +
      '  warmup_sent_today INTEGER DEFAULT 0,' +
      '  last_send_date TEXT' +
      ');'
    );

    Conn.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS send_logs (' +
      '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  contact_id INTEGER,' +
      '  campaign_id INTEGER,' +
      '  smtp_id INTEGER,' +
      '  status TEXT,' +
      '  message_id TEXT,' +
      '  sent_at DATETIME DEFAULT CURRENT_TIMESTAMP' +
      ');'
    );
    Conn.ExecuteDirect('CREATE INDEX IF NOT EXISTS idx_logs_msgid ON send_logs(message_id);');

    Trans.Commit;

    // 3. Smart Auto-Migrate (Prevents Debugger Exceptions)
    if not ColumnExists(Conn, Trans, 'smtp_profiles', 'is_warmup') then
    begin
      if not Trans.Active then Trans.StartTransaction;
      Conn.ExecuteDirect('ALTER TABLE smtp_profiles ADD COLUMN is_warmup INTEGER DEFAULT 0;');
      Trans.Commit;
    end;

    if not ColumnExists(Conn, Trans, 'smtp_profiles', 'warmup_day') then
    begin
      if not Trans.Active then Trans.StartTransaction;
      Conn.ExecuteDirect('ALTER TABLE smtp_profiles ADD COLUMN warmup_day INTEGER DEFAULT 1;');
      Trans.Commit;
    end;

    if not ColumnExists(Conn, Trans, 'smtp_profiles', 'warmup_sent_today') then
    begin
      if not Trans.Active then Trans.StartTransaction;
      Conn.ExecuteDirect('ALTER TABLE smtp_profiles ADD COLUMN warmup_sent_today INTEGER DEFAULT 0;');
      Trans.Commit;
    end;

    if not ColumnExists(Conn, Trans, 'smtp_profiles', 'last_send_date') then
    begin
      if not Trans.Active then Trans.StartTransaction;
      Conn.ExecuteDirect('ALTER TABLE smtp_profiles ADD COLUMN last_send_date TEXT;');
      Trans.Commit;
    end;

    if Trans.Active then Trans.Commit;

    TLogger.Instance.Log('Database schema is ready.', llInfo);
  except
    on E: Exception do
    begin
      if Trans.Active then Trans.Rollback;
      TLogger.Instance.Log('Database schema initialization error: ' + E.Message, llError);
    end;
  end;

  Conn.Free;
end;

initialization
  TDbManager.FInstance := nil;

finalization
  if Assigned(TDbManager.FInstance) then
    TDbManager.FInstance.Free;

end.
