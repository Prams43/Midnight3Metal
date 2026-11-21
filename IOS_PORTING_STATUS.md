# Status Port iOS — MC3 Xbox Recomp

Dokumen ini mencatat hasil audit dan perubahan port yang sudah ada. Ini bukan klaim bahwa aplikasi iOS sudah bisa dibangun atau dimainkan.

## Fondasi yang tersedia

- `sdk/runtime/core/input.h` dan `input.cpp` menyediakan `VirtualControl`, `SetVirtualControl`, dan `OnScancode` untuk input host non-keyboard. Kontrol virtual diterjemahkan ke laporan pad Xbox pada port 0.
- `sdk/runtime/app/ios_touch_controls.h` dan `.mm` menyediakan overlay UIKit dengan tombol arah, tombol muka, shoulder, Back, dan Start yang meneruskan press/release ke `SetVirtualControl`. Overlay belum dihubungkan ke host game.
- `sdk/runtime/audio/audio_apple.mm` berisi implementasi awal output stereo float melalui Audio Queue Services untuk Apple. Implementasi belum dimasukkan ke target production atau diuji.
- `ios-memory-probe/` adalah aplikasi diagnostik standalone; bukan game.

## Port production: batas saat ini

Belum tersedia target game iOS, app host UIKit dengan lifecycle game, Metal renderer, bundling aset yang aman, atau IPA game.

`CMakeLists.txt` dan `sdk/cmake/XbeRecomp.cmake` saat ini mengatur executable Win32. Runtime memakai entry point `wWinMain`, Win32 window/message loop, ImGui Win32/DX12, D3D12/DXGI, XAudio2, dan pustaka Windows lain. `sdk/runtime/gpu/d3d12.cpp` adalah backend produksi; `gpu/ext.h` masih mengekspos tipe D3D12 langsung. Guest memory juga mengasumsikan layout alamat tetap 4 GiB; probe pada iPhone menunjukkan alamat hint yang diminta tidak dipilih iOS. Audio Apple dan touch overlay belum terintegrasi dengan game host.

## Progress compile-check iOS bertahap

Ditambahkan target opsional `ios-game-runtime/` yang dimaksudkan mengompilasi `input.cpp`, `log.cpp`, serta `ios_touch_controls.mm` terhadap iOS SDK dan SDL3 statis. Pemilihannya melalui `-DMC3_IOS_TARGET=game-runtime-check`. Workflow `.github/workflows/ios-build.yml` menambahkan job `ios-game-runtime-compile-check` untuk membangunnya di runner macOS.

Target ini hanya compile-check untuk komponen input/UI. Ia tidak membangun executable atau IPA, tidak menghubungkan overlay ke game, dan tidak memverifikasi perilaku runtime. Perubahan CMake dan workflow belum diverifikasi; hasil GitHub Actions masih diperlukan. Bila build gagal, perbaiki berdasarkan error runner sebelum memperluas daftar source.

## Langkah berikutnya

1. Jalankan job `ios-game-runtime-compile-check` dan perbaiki error kompilasi yang benar-benar dilaporkan.
2. Buat host UIKit/MetalKit dengan lifecycle boot/pause/resume/stop, tanpa mengklaim renderer tersedia sebelum implementasi dan tes.
3. Rancang ulang guest-memory/address translation agar tidak mensyaratkan alamat tetap yang tidak dipenuhi iOS; uji sebelum menghubungkan runtime penuh.
4. Pisahkan kontrak ekstensi GPU dari D3D12, lalu implementasikan renderer Metal bertahap dan uji clear/draw/present pada test scene.
5. Integrasikan Audio Queue dengan start/stop, interupsi, perubahan audio route, dan pemulihan error; uji di perangkat.
6. Audit filesystem, thread/sinkronisasi, exception handling, dan networking. Bangun di macOS/Xcode setelah setiap lapisan.
7. Integrasikan hanya konten yang pengguna berhak distribusikan dan lakukan uji end-to-end di iPhone sebelum menyebut IPA game siap.

## Verifikasi

Input virtual dan pemisahan vertex format telah diperiksa statis pada pekerjaan terdahulu. Backing store memori iOS, perubahan signature thread Darwin, dan audio Apple belum dikompilasi/diuji dengan Apple SDK menurut catatan audit sebelumnya. Workflow yang baru diubah belum dijalankan pada macOS CI. Kompilasi source saja tidak membuktikan runtime bekerja.

Windows masih dapat digunakan untuk meninjau source. Kompilasi iOS memerlukan runner macOS/Xcode; validasi akhir memerlukan perangkat iOS. Aset game dan kode hasil recompile tidak boleh dimasukkan ke repositori publik tanpa hak distribusi yang jelas.
