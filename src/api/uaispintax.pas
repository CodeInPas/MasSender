unit uAiSpintax;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, fpjson, jsonparser, opensslsockets;

type
  TAiProvider = (apLocal, apGemini);

  // Event handler untuk mengembalikan hasil ke UI thread
  TOnAiComplete = procedure(const ASpintaxResult: string) of object;
  TOnAiError = procedure(const AErrorMsg: string) of object;

  { TAiSpintaxGenerator }
  // Thread asinkron untuk memanggil API AI agar antarmuka tidak freeze
  TAiSpintaxGenerator = class(TThread)
  private
    FProvider: TAiProvider;
    FApiKey: string;
    FEndpoint: string;
    FOriginalText: string;

    FResultText: string;
    FErrorMessage: string;

    FOnComplete: TOnAiComplete;
    FOnError: TOnAiError;

    procedure CallGeminiAPI;
    procedure CallLocalAPI;

    // Method untuk sinkronisasi hasil ke Main UI Thread
    procedure SyncComplete;
    procedure SyncError;
  protected
    procedure Execute; override;
  public
    constructor Create(AProvider: TAiProvider; const AEndpoint, AApiKey, AText: string);

    property OnComplete: TOnAiComplete read FOnComplete write FOnComplete;
    property OnError: TOnAiError read FOnError write FOnError;
  end;

  // Fungsi utilitas untuk mengeksekusi spintax pada teks (dipanggil oleh uSmtpWorker saat runtime)
  function EvaluateSpintax(const AText: string): string;

implementation

// Fungsi helper lokal untuk membersihkan string agar valid dimasukkan ke dalam JSON
function EscapeJSONString(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
end;

{ TAiSpintaxGenerator }

constructor TAiSpintaxGenerator.Create(AProvider: TAiProvider; const AEndpoint, AApiKey, AText: string);
begin
  inherited Create(True); // Buat dalam keadaan Suspended
  FreeOnTerminate := True;
  FProvider := AProvider;
  FEndpoint := AEndpoint;
  FApiKey := AApiKey;
  FOriginalText := AText;
end;

procedure TAiSpintaxGenerator.SyncComplete;
begin
  if Assigned(FOnComplete) then FOnComplete(FResultText);
end;

procedure TAiSpintaxGenerator.SyncError;
begin
  if Assigned(FOnError) then FOnError(FErrorMessage);
end;

procedure TAiSpintaxGenerator.Execute;
begin
  try
    if FProvider = apGemini then
      CallGeminiAPI
    else
      CallLocalAPI;

    Synchronize(@SyncComplete);
  except
    on E: Exception do
    begin
      FErrorMessage := E.Message;
      Synchronize(@SyncError);
    end;
  end;
end;

procedure TAiSpintaxGenerator.CallGeminiAPI;
var
  HTTP: TFPHTTPClient;
  JsonReq, JsonResponse: TJSONData;
  ReqBody, RespStr: string;
  PromptInfo: string;
  ReqStream: TStringStream; // PERBAIKAN: Stream untuk menampung request JSON
begin
  PromptInfo := 'Tulis ulang teks berikut menjadi format spintax email marketing untuk menghindari filter spam. Gunakan format {kata1|kata2|kata3}. Pertahankan tag [Name]. Teks asli: ' + FOriginalText;

  // Format Payload Gemini API (v1beta/models/gemini-pro:generateContent)
  ReqBody := Format('{"contents":[{"parts":[{"text":"%s"}]}]}', [EscapeJSONString(PromptInfo)]);

  HTTP := TFPHTTPClient.Create(nil);
  ReqStream := TStringStream.Create(ReqBody);
  try
    HTTP.AddHeader('Content-Type', 'application/json');

    // PERBAIKAN: Gunakan RequestBody untuk menampung data POST
    HTTP.RequestBody := ReqStream;

    // Asumsi FEndpoint adalah url lengkap termasuk API Key parameter
    RespStr := HTTP.Post(FEndpoint);

    JsonResponse := GetJSON(RespStr);
    try
      // Ekstrak hasil dari JSON response Gemini
      FResultText := JsonResponse.FindPath('candidates[0].content.parts[0].text').AsString;
    finally
      JsonResponse.Free;
    end;
  finally
    ReqStream.Free;
    HTTP.Free;
  end;
end;

procedure TAiSpintaxGenerator.CallLocalAPI;
var
  HTTP: TFPHTTPClient;
  JsonResponse: TJSONData;
  ReqBody, RespStr: string;
  PromptInfo: string;
  ReqStream: TStringStream; // PERBAIKAN: Stream untuk menampung request JSON
begin
  PromptInfo := 'Rewrite this marketing email into spintax format like {word1|word2}. Keep the [Name] tag intact. Original text: ' + FOriginalText;

  // Format standar OpenAI Chat Completions (digunakan oleh Ollama & llama.cpp server)
  ReqBody := Format('{"messages": [{"role": "user", "content": "%s"}]}', [EscapeJSONString(PromptInfo)]);

  HTTP := TFPHTTPClient.Create(nil);
  ReqStream := TStringStream.Create(ReqBody);
  try
    HTTP.AddHeader('Content-Type', 'application/json');
    if FApiKey <> '' then
      HTTP.AddHeader('Authorization', 'Bearer ' + FApiKey);

    // PERBAIKAN: Gunakan RequestBody untuk menampung data POST
    HTTP.RequestBody := ReqStream;

    RespStr := HTTP.Post(FEndpoint);

    JsonResponse := GetJSON(RespStr);
    try
      // Ekstrak hasil dari local server JSON response
      FResultText := JsonResponse.FindPath('choices[0].message.content').AsString;
    finally
      JsonResponse.Free;
    end;
  finally
    ReqStream.Free;
    HTTP.Free;
  end;
end;

// ==============================================================================
// SPINTAX PARSER ENGINE
// ==============================================================================

function EvaluateSpintax(const AText: string): string;
var
  StartPos, EndPos, PipePos: Integer;
  OptionsStr: string;
  OptionsArr: TStringArray;
  SelectedStr: string;
begin
  Result := AText;
  Randomize; // Pastikan seed acak sudah diinisialisasi

  // Terus cari tanda kurawal buka '{' selama masih ada di dalam teks
  while True do
  begin
    StartPos := Pos('{', Result);
    if StartPos = 0 then Break; // Tidak ada lagi spintax, keluar dari loop

    EndPos := Pos('}', Result, StartPos);
    if EndPos = 0 then Break; // Format salah (tidak ada kurung tutup), abaikan

    // Ekstrak string di dalam tanda kurung kurawal (contoh: "Halo|Hai|Salam")
    OptionsStr := Copy(Result, StartPos + 1, EndPos - StartPos - 1);

    // Pecah string berdasarkan pembatas '|'
    OptionsArr := OptionsStr.Split('|');

    if Length(OptionsArr) > 0 then
    begin
      // Pilih salah satu opsi secara acak
      SelectedStr := OptionsArr[Random(Length(OptionsArr))];
      // Gantikan format spintax {A|B} dengan opsi yang terpilih di dalam Result
      Result := Copy(Result, 1, StartPos - 1) + SelectedStr + Copy(Result, EndPos + 1, Length(Result));
    end
    else
      Break; // Pengaman dari infinite loop jika parsing gagal
  end;
end;

end.
