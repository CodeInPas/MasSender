unit uCampaignRepo;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, uDbConnection, uLogger;

type
  // TCampaign: Lightweight record to carry data from the database to the UI or Worker Thread
  TCampaign = record
    ID: Integer;
    Name: string;
    TemplateText: string;
    CreatedAt: TDateTime;
  end;
  TCampaignArray = array of TCampaign;

  { TCampaignRepo }
  TCampaignRepo = class
  public
    class function GetAll: TCampaignArray;
    class function GetByID(const AID: Integer): TCampaign;
    class function Save(const AName, ATemplateText: string; const AID: Integer = 0): Integer;
    class procedure Delete(const AID: Integer);
  end;

implementation

{ TCampaignRepo }

class function TCampaignRepo.GetAll: TCampaignArray;
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
      Qry.SQL.Text := 'SELECT id, name, template_text, created_at FROM campaigns ORDER BY id DESC';
      Qry.Open;

      Idx := 0;
      // FIX: Use incremental Dynamic Array allocation
      while not Qry.EOF do
      begin
        if Idx >= Length(Result) then
          SetLength(Result, Length(Result) + 20);

        Result[Idx].ID := Qry.FieldByName('id').AsInteger;
        Result[Idx].Name := Qry.FieldByName('name').AsString;
        Result[Idx].TemplateText := Qry.FieldByName('template_text').AsString;
        Result[Idx].CreatedAt := Qry.FieldByName('created_at').AsDateTime;
        Inc(Idx);
        Qry.Next;
      end;

      // Trim excess memory
      SetLength(Result, Idx);
    except
      on E: Exception do
        TLogger.Instance.Log('TCampaignRepo.GetAll Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TCampaignRepo.GetByID(const AID: Integer): TCampaign;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  Result.ID := 0;
  Result.Name := '';
  Result.TemplateText := '';

  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'SELECT id, name, template_text FROM campaigns WHERE id = :id';
      Qry.ParamByName('id').AsInteger := AID;
      Qry.Open;

      if not Qry.EOF then
      begin
        Result.ID := Qry.FieldByName('id').AsInteger;
        Result.Name := Qry.FieldByName('name').AsString;
        Result.TemplateText := Qry.FieldByName('template_text').AsString;
      end;
    except
      on E: Exception do
        TLogger.Instance.Log('TCampaignRepo.GetByID Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TCampaignRepo.Save(const AName, ATemplateText: string; const AID: Integer): Integer;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  Result := AID;
  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;

      if not Trans.Active then
        Trans.StartTransaction;

      if AID = 0 then
      begin
        Qry.SQL.Text := 'INSERT INTO campaigns (name, template_text) VALUES (:name, :template_text)';
        Qry.ParamByName('name').AsString := Trim(AName);
        Qry.ParamByName('template_text').AsString := ATemplateText;
        Qry.ExecSQL;

        Qry.SQL.Text := 'SELECT last_insert_rowid() AS new_id';
        Qry.Open;
        Result := Qry.FieldByName('new_id').AsInteger;
        Qry.Close;
      end
      else
      begin
        Qry.SQL.Text := 'UPDATE campaigns SET name = :name, template_text = :template_text WHERE id = :id';
        Qry.ParamByName('name').AsString := Trim(AName);
        Qry.ParamByName('template_text').AsString := ATemplateText;
        Qry.ParamByName('id').AsInteger := AID;
        Qry.ExecSQL;
      end;
      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('TCampaignRepo.Save Error: ' + E.Message, llError);
        Result := 0;
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TCampaignRepo.Delete(const AID: Integer);
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
      Qry.SQL.Text := 'DELETE FROM campaigns WHERE id = :id';

      if not Trans.Active then
        Trans.StartTransaction;

      Qry.ParamByName('id').AsInteger := AID;
      Qry.ExecSQL;
      Trans.Commit;

      TLogger.Instance.Log(Format('Campaign ID %d successfully deleted.', [AID]), llInfo);
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('TCampaignRepo.Delete Error: ' + E.Message, llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

end.
