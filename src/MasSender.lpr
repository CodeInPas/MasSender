program MasSender;

{$mode objfpc}{$H+}

uses
  // Mengaktifkan dukungan Multithreading bawaan sistem operasi.
  // Sangat krusial karena mesin pengirim kita menggunakan TThread.
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}

  Interfaces, // LCL widgetset (wajib untuk aplikasi GUI)
  Forms,

  // Pendaftaran unit form agar dikompilasi oleh FPC
  frmMain, frmDashboard, frmContacts, frmCampaigns, frmSettings;

// Arahan untuk menyertakan file resource (.res) seperti Icon aplikasi dan Manifest OS
{$R *.res}

begin
  RequireDerivedFormResource := True;

  // Konfigurasi DPI Awareness agar tampilan tetap tajam di monitor resolusi tinggi (4K)
  Application.Scaled:=True;

  Application.Initialize;

  // OPTIMASI EKSTREM:
  // HANYA Main Form yang dialokasikan ke memori saat startup (aplikasi dibuka).
  // Sub-form seperti frmDashboard, frmContacts, dll. akan dialokasikan
  // secara dinamis (Lazy Loading) oleh frmMain HANYA JIKA pengguna mengklik menu tersebut.
  Application.CreateForm(TfrmMainForm, frmMainForm);

  // Mulai putaran event utama (Main Event Loop)
  Application.Run;
end.

