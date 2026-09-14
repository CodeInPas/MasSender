unit uAnalyticsClient;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, fpjson, jsonparser, uAppConfig, uLogger;

type
  // TCampaignStats: Record ringan untuk membawa hasil analitik ke UI (Dashboard)
  TCampaignStats = record
    CampaignID: Integer;
    Sent: Integer;
    Opens: Integer;
    Clicks: Integer;
    Unsubscribes: Integer;
    Bounces: Integer;
    IsSuccess: Boolean; // Flag untuk mengetahui apakah request API berhasil
  end;

  { TAnalyticsClient }
  // Menggunakan Class Methods agar bisa langsung dipanggil dari Timer di UI
  // tanpa perlu membuat dan menghancurkan objek berulang kali.
  TAnalyticsClient = class
  public
    // Melakukan HTTP GET ke web tracker klien dan mem-parsing respons JSON-nya
    class function FetchStats(const ACampaignID: Integer): TCampaignStats;
  end;

implementation

{ TAnalyticsClient }

class function TAnalyticsClient.FetchStats(const ACampaignID: Integer): TCampaignStats;
var
  HTTPClient: TFPHTTPClient;
  JsonResponse: string;
  JsonData: TJSONData;
  JsonObject: TJSONObject;
  RequestUrl: string;
begin
  // 1. Inisialisasi record hasil dengan angka 0 (Zeroing memory)
  FillByte(Result, SizeOf(TCampaignStats), 0);
  Result.CampaignID := ACampaignID;
  Result.IsSuccess := False;

  RequestUrl := TAppConfig.Instance.WebTrackingUrl;
  if Trim(RequestUrl) = '' then
  begin
    TLogger.Instance.Log('AnalyticsClient: WebTrackingUrl belum dikonfigurasi di Settings.', llWarning);
    Exit;
  end;

  // Menyusun URL Endpoint (contoh: https://domain.com/tracker.php?action=get_stats&campaign_id=1)
  RequestUrl := RequestUrl + '?action=get_stats&campaign_id=' + IntToStr(ACampaignID);

  HTTPClient := TFPHTTPClient.Create(nil);
  try
    try
      // OPTIMASI KRITIS: Timeout sangat penting!
      // Jika server klien down/lambat, aplikasi desktop tidak boleh ikut "Not Responding".
      HTTPClient.ConnectTimeout := 5000; // Maksimal 5 detik menunggu koneksi
      HTTPClient.IOTimeout := 5000;      // Maksimal 5 detik menunggu balasan data
      HTTPClient.AllowRedirect := True;

      // 2. Eksekusi HTTP GET Request
      JsonResponse := HTTPClient.Get(RequestUrl);

      // 3. Parsing String JSON ke dalam bentuk Objek
      JsonData := GetJSON(JsonResponse);
      try
        // Pastikan balasan benar-benar sebuah JSON Object (bukan array atau teks biasa)
        if Assigned(JsonData) and (JsonData.JSONType = jtObject) then
        begin
          JsonObject := TJSONObject(JsonData);

          // Ekstraksi nilai secara aman. Fungsi Get(Key, DefaultValue) akan
          // mengembalikan nilai 0 jika key tidak ditemukan di JSON, mencegah exception.
          Result.Opens := JsonObject.Get('opens', 0);
          Result.Clicks := JsonObject.Get('clicks', 0);
          Result.Unsubscribes := JsonObject.Get('unsubscribes', 0);
          Result.Sent := JsonObject.Get('sent', 0);
          Result.Bounces := JsonObject.Get('bounces', 0);

          Result.IsSuccess := True;
        end
        else
        begin
          TLogger.Instance.Log('AnalyticsClient: Format JSON respons tidak valid/bukan object.', llError);
        end;
      finally
        // Wajib membebaskan TJSONData untuk menghindari memory leak (kebocoran RAM)
        JsonData.Free;
      end;

    except
      on E: Exception do
      begin
        // Telan exception agar aplikasi utama tidak crash, cukup catat di log
        TLogger.Instance.Log(Format('AnalyticsClient Error [%s]: %s', [RequestUrl, E.Message]), llError);
      end;
    end;
  finally
    HTTPClient.Free;
  end;
end;

end.

