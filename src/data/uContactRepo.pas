unit uContactRepo;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, uDbConnection, uLogger;

type
  TContact = record
    ID: Integer;
    Email: string;
    Name: string;
    Status: string;
  end;
  TContactArray = array of TContact;

  { TContactRepo }
  TContactRepo = class
  public
    // Mengambil kontak yang masih 'Active' untuk Worker
    class function GetActiveContacts(ALimit: Integer): TContactArray;

    // BARU: Mengambil seluruh data terbaru (semua status) untuk UI Dashboard
    class function GetPreviewContacts(ALimit: Integer): TContactArray;
    class procedure CancelAllActiveQueue;
    class procedure BulkInsert(const AContacts: TContactArray);
    class procedure UpdateStatus(const AEmail: string; const ANewStatus: string);
    class function GetCountByStatus(const AStatus: string): Integer;
  end;

implementation

{ TContactRepo }

class function TContactRepo.GetActiveContacts(ALimit: Integer): TContactArray;
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
      Qry.SQL.Text := 'SELECT id, email, name, status FROM contacts WHERE status = ''Active'' LIMIT :Lim';
      Qry.ParamByName('Lim').AsInteger := ALimit;
      Qry.Open;

      Idx := 0;
      // PERBAIKAN: Array dinamis, tidak mengandalkan Qry.RecordCount yang sering bernilai 0 di SQLite
      while not Qry.EOF do
      begin
        if Idx >= Length(Result) then
          SetLength(Result, Length(Result) + 100); // Naikkan kapasitas memori bertahap

        Result[Idx].ID := Qry.FieldByName('id').AsInteger;
        Result[Idx].Email := Qry.FieldByName('email').AsString;
        Result[Idx].Name := Qry.FieldByName('name').AsString;
        Result[Idx].Status := Qry.FieldByName('status').AsString;
        Inc(Idx);
        Qry.Next;
      end;
      // Pangkas sisa memori kosong di akhir
      SetLength(Result, Idx);
    except
      on E: Exception do
        TLogger.Instance.Log('GetActiveContacts Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TContactRepo.GetPreviewContacts(ALimit: Integer): TContactArray;
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
      // Ambil semua data (tanpa filter status), urutkan dari ID terbesar (terbaru)
      Qry.SQL.Text := 'SELECT id, email, name, status FROM contacts ORDER BY id DESC LIMIT :Lim';
      Qry.ParamByName('Lim').AsInteger := ALimit;
      Qry.Open;

      Idx := 0;
      while not Qry.EOF do
      begin
        if Idx >= Length(Result) then
          SetLength(Result, Length(Result) + 100);

        Result[Idx].ID := Qry.FieldByName('id').AsInteger;
        Result[Idx].Email := Qry.FieldByName('email').AsString;
        Result[Idx].Name := Qry.FieldByName('name').AsString;
        Result[Idx].Status := Qry.FieldByName('status').AsString;
        Inc(Idx);
        Qry.Next;
      end;
      SetLength(Result, Idx);
    except
      on E: Exception do
        TLogger.Instance.Log('GetPreviewContacts Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TContactRepo.BulkInsert(const AContacts: TContactArray);
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
      Qry.SQL.Text := 'INSERT OR IGNORE INTO contacts (email, name, status) VALUES (:email, :name, ''Active'')';
      Qry.Prepare;

      if not Trans.Active then Trans.StartTransaction;

      for i := 0 to High(AContacts) do
      begin
        Qry.ParamByName('email').AsString := LowerCase(Trim(AContacts[i].Email));
        Qry.ParamByName('name').AsString := Trim(AContacts[i].Name);
        Qry.ExecSQL;
      end;
      Trans.Commit;
      TLogger.Instance.Log(Format('Berhasil mengimpor batch berisi %d kontak.', [Length(AContacts)]), llInfo);
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('BulkInsert Error: ' + E.Message, llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class procedure TContactRepo.UpdateStatus(const AEmail: string; const ANewStatus: string);
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
      Qry.SQL.Text := 'UPDATE contacts SET status = :status WHERE email = :email';

      if not Trans.Active then Trans.StartTransaction;

      Qry.ParamByName('status').AsString := ANewStatus;
      Qry.ParamByName('email').AsString := LowerCase(Trim(AEmail));
      Qry.ExecSQL;
      Trans.Commit;
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log(Format('UpdateStatus Error untuk %s: %s', [AEmail, E.Message]), llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;

class function TContactRepo.GetCountByStatus(const AStatus: string): Integer;
var
  Conn: TSQLite3Connection;
  Trans: TSQLTransaction;
  Qry: TSQLQuery;
begin
  Result := 0;
  Conn := TDbManager.Instance.CreateNewConnection(Trans);
  Qry := TSQLQuery.Create(nil);
  try
    try
      Qry.DataBase := Conn;
      Qry.Transaction := Trans;
      Qry.SQL.Text := 'SELECT COUNT(*) AS total FROM contacts WHERE status = :status';
      Qry.ParamByName('status').AsString := AStatus;
      Qry.Open;
      Result := Qry.FieldByName('total').AsInteger;
    except
      on E: Exception do
        TLogger.Instance.Log('GetCountByStatus Error: ' + E.Message, llError);
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;
class procedure TContactRepo.CancelAllActiveQueue;
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

      // PERBAIKAN: Ubah semua yang 'Active' maupun 'Queued' menjadi 'Cancelled'
      Qry.SQL.Text := 'UPDATE contacts SET status = ''Cancelled'' WHERE status  IN ( ''Active'',''Queued'')';

      if not Trans.Active then
        Trans.StartTransaction;

      Qry.ExecSQL;
      Trans.Commit;

      TLogger.Instance.Log('Seluruh antrean (Active & Queued) berhasil dibatalkan oleh pengguna.', llInfo);
    except
      on E: Exception do
      begin
        if Trans.Active then Trans.Rollback;
        TLogger.Instance.Log('CancelAllActiveQueue Error: ' + E.Message, llError);
      end;
    end;
  finally
    Qry.Free;
    Conn.Free;
  end;
end;
end.
