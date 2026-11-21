# Rencana teknis port iOS — MC3 Xbox Recomp

Dokumen ini memecah pekerjaan port berdasarkan batas kode yang sudah ditemukan. Status “fondasi” hanya berarti ada perubahan source, bukan keberhasilan build atau validasi game.

## 1. Input

Fondasi: `input::VirtualControl`, `SetVirtualControl`, dan `OnScancode` mengubah input host menjadi laporan `Pad` Xbox. `ios_touch_controls.h/.mm` menyediakan HUD UIKit dasar dengan D-pad, tombol muka, shoulder, Back, dan Start; API dapat menerima kontrol virtual. UIKit kini hanya dideklarasikan/diimplementasikan pada `TARGET_OS_IPHONE`. Belum ada host iOS yang memanggil HUD.

Berikutnya: integrasikan overlay ke host UIKit/MetalKit, verifikasi multi-touch press/release per jari, lifecycle pause/resume dan layout pada perangkat; pertimbangkan left/right trigger serta opsi posisi/opacity.

## 2. Audio

Fondasi: `sdk/runtime/audio/audio_apple.mm` adalah upaya awal output Audio Queue stereo float 48 kHz yang menggunakan callback mixer `audio::StartOutput`.

Sebelum dipakai: pastikan callback dan antrean buffer sesuai kontrak Audio Queue, tangani interruption/route/background, buat kepemilikan state dan shutdown yang eksplisit, pilih AVAudioSession yang sesuai, lalu kompilasi dan uji latency serta stabilitas pada perangkat Apple. CMake masih mengompilasi `xaudio2.cpp` untuk host Windows dan belum memilih file Apple.

## 3. Grafik

Belum ada implementasi Metal. `gpu::Backend` menyediakan batas kelas untuk operasi D3D8 yang sudah diterjemahkan, tetapi `gpu/ext.h` mengekspos langsung `ID3D12Resource`, command list, descriptor dan DXGI format. Renderer D3D12 dan host extension terikat erat pada Windows. Jangan memasukkan stub yang pura-pura merender: port perlu terlebih dahulu memisahkan kontrak extension dari tipe D3D12, kemudian mengimplementasikan resource, state, shader translation, copy/readback, present dan sinkronisasi Metal.

## 4. Host aplikasi dan kernel

Belum ada iOS entry point/target. `app/main.cpp` memakai `wWinMain`, Win32 window/message loop, direktori executable, crash dumps, splash dan handover. `app.h` juga mengekspos kontrak HWND. Kernel, disk, guest-memory dan thread code memiliki banyak Win32 API. Pisahkan interface platform dari implementasi Windows, lalu buat host UIKit/MetalKit dan adapter file sandbox.

Go/no-go awal sebelum renderer penuh: audit dan prototipe pemetaan memori guest Xbox serta virtual-address assumptions di iOS. Jika kebutuhan address reservation/protection tidak dapat dipenuhi oleh iOS, runtime harus direkayasa ulang sebelum port dapat boot.

## 5. Build dan batas validasi

Belum ada target Xcode, konfigurasi CMake iOS yang lengkap, bundle aset, atau IPA. Build Apple membutuhkan macOS/Xcode secara lokal atau CI macOS. Di lingkungan saat ini perubahan hanya bisa ditinjau statis; AudioToolbox, Metal, UIKit, Xcode build, dan perilaku pada perangkat belum diverifikasi.
