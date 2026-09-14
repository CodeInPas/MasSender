unit uDnsChecker;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, IdDNSResolver, IdGlobal, TypInfo, uLogger; // FIX: Added TypInfo

type
  { TDnsChecker }
  // Utility class (static) to validate DNS records before a campaign runs.
  TDnsChecker = class
  private
    // Internal helper to query TXT records to a public DNS Server (Google DNS)
    class function QueryTXTRecord(const AQueryDomain: string; const AExpectedPrefix: string; out AFoundRecord: string): Boolean;
  public
    // Checks the Sender Policy Framework (SPF) record
    class function CheckSPF(const ADomain: string; out ARecord: string): Boolean;

    // Checks the Domain-based Message Authentication, Reporting, and Conformance (DMARC) record
    class function CheckDMARC(const ADomain: string; out ARecord: string): Boolean;

    // Checks the DomainKeys Identified Mail (DKIM) record. Requires a Selector name.
    class function CheckDKIM(const ADomain: string; const ASelector: string; out ARecord: string): Boolean;

    // Aggregate function to be validated directly in the UI with 1 click
    class function ValidateDomainHealth(const ADomain: string; const ADkimSelector: string = ''): Boolean;
  end;

implementation

{ TDnsChecker }

class function TDnsChecker.QueryTXTRecord(const AQueryDomain: string; const AExpectedPrefix: string; out AFoundRecord: string): Boolean;
var
  DNS: TIdDNSResolver;
  i, j: Integer;
  Obj, PropObj: TObject;
  StrList: TStrings;
  TxtLine: string;
begin
  Result := False;
  AFoundRecord := '';

  // Local instantiation. Very safe and efficient if called from within a Worker Thread.
  DNS := TIdDNSResolver.Create(nil);
  try
    try
      // Using Google Public DNS (very fast & aggressive caching)
      DNS.Host := '8.8.8.8';

      // Indy 10 handles timeouts internally
      DNS.QueryType := [qtTXT];

      DNS.Resolve(AQueryDomain);

      for i := 0 to DNS.QueryResult.Count - 1 do
      begin
        Obj := DNS.QueryResult[i];

        // FINAL FIX (Dynamic RTTI):
        // Extracts the "Text" value without needing to know the original Class name.
        // This ensures the code remains working in ALL Indy FPC versions.
        if Assigned(Obj) and IsPublishedProp(Obj, 'Text') then
        begin
          PropObj := GetObjectProp(Obj, 'Text');
          if PropObj is TStrings then
          begin
            StrList := TStrings(PropObj);
            TxtLine := '';

            // Indy splits long strings into multiple lines (TStrings), we concatenate them back.
            for j := 0 to StrList.Count - 1 do
              TxtLine := TxtLine + StrList[j];

            // Efficient validation: Check if data starts with the expected prefix
            if Pos(AExpectedPrefix, TxtLine) = 1 then
            begin
              AFoundRecord := TxtLine;
              Result := True;
              Break; // Exit the loop immediately after validation
            end;
          end;
        end;
      end;
    except
      on E: Exception do
        TLogger.Instance.Log(Format('DNS Query Error [%s]: %s', [AQueryDomain, E.Message]), llError);
    end;
  finally
    DNS.Free;
  end;
end;

class function TDnsChecker.CheckSPF(const ADomain: string; out ARecord: string): Boolean;
begin
  // SPF is always placed at the root domain. The opening tag must be exactly "v=spf1"
  Result := QueryTXTRecord(ADomain, 'v=spf1', ARecord);
end;

class function TDnsChecker.CheckDMARC(const ADomain: string; out ARecord: string): Boolean;
begin
  // DMARC is always located in the special "_dmarc" subdomain
  Result := QueryTXTRecord('_dmarc.' + ADomain, 'v=DMARC1', ARecord);
end;

class function TDnsChecker.CheckDKIM(const ADomain: string; const ASelector: string; out ARecord: string): Boolean;
begin
  if Trim(ASelector) = '' then
  begin
    ARecord := 'DKIM Selector is not provided.';
    Exit(False);
  end;

  // DKIM is placed in the format [selector]._domainkey.[domain]
  Result := QueryTXTRecord(ASelector + '._domainkey.' + ADomain, 'v=DKIM1', ARecord);
end;

class function TDnsChecker.ValidateDomainHealth(const ADomain: string; const ADkimSelector: string): Boolean;
var
  Rec: string;
  IsSpfOk, IsDmarcOk: Boolean;
begin
  TLogger.Instance.Log('Starting Pre-Flight DNS Check for domain: ' + ADomain, llInfo);

  IsSpfOk := CheckSPF(ADomain, Rec);
  if IsSpfOk then
    TLogger.Instance.Log('✅ Valid SPF: ' + Rec, llInfo)
  else
    TLogger.Instance.Log('❌ SPF Not Found/Invalid. High risk of emails entering Spam.', llWarning);

  IsDmarcOk := CheckDMARC(ADomain, Rec);
  if IsDmarcOk then
    TLogger.Instance.Log('✅ Valid DMARC: ' + Rec, llInfo)
  else
    TLogger.Instance.Log('❌ DMARC Not Found/Invalid.', llWarning);

  // If the client inputs a selector, we also check its DKIM
  if ADkimSelector <> '' then
  begin
    if CheckDKIM(ADomain, ADkimSelector, Rec) then
      TLogger.Instance.Log('✅ Valid DKIM (' + ADkimSelector + '): ' + Rec, llInfo)
    else
      TLogger.Instance.Log('❌ DKIM Not Found for selector: ' + ADkimSelector, llWarning);
  end;

  // Minimum requirement for 70% deliverability score: Domain must have correct SPF and DMARC
  Result := IsSpfOk and IsDmarcOk;
end;

end.
