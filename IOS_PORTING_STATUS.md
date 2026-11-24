# Status Port iOS — MC3 Xbox Recomp

Dokumen ini mencatat hasil audit dan perubahan port yang sudah ada. Ini bukan klaim bahwa aplikasi iOS sudah bisa dibangun atau dimainkan.

## Fondasi yang tersedia

- `sdk/runtime/core/input.h` dan `input.cpp` menyediakan `VirtualControl`, `SetVirtualControl`, dan `OnScancode` untuk input host non-keyboard. Kontrol virtual diterjemahkan ke laporan pad Xbox pada port 0.
- `sdk/runtime/app/ios_touch_controls.h` dan `.mm` menyediakan overlay UIKit dengan tombol arah, tombol muka, shoulder, Back, dan Start yang meneruskan press/release ke `SetVirtualControl`.
- `ios-app/` menyediakan UIKit app host dengan `AppDelegate`, `ViewController`, dan lifecycle app iOS. App menampilkan touch overlay dan menjalankan placeholder game loop menggunakan `CADisplayLink`. Ini adalah executable iOS pertama yang dapat di-deploy ke perangkat, tetapi belum menjalankan game sebenarnya.
- `sdk/runtime/audio/audio_apple.mm` berisi implementasi awal output stereo float melalui Audio Queue Services untuk Apple. Implementasi belum dimasukkan ke target production atau diuji.
- `ios-memory-probe/` adalah aplikasi diagnostik standalone; bukan game.

## Port production: batas saat ini

Tersedia iOS app host dengan UIKit lifecycle dan touch overlay terintegrasi (`ios-app/`), tetapi belum tersedia Metal renderer, integrasi game logic/engine, guest memory portabel, atau game IPA yang playable.

`CMakeLists.txt` dan `sdk/cmake/XbeRecomp.cmake` saat ini mengatur executable Win32. Runtime memakai entry point `wWinMain`, Win32 window/message loop, ImGui Win32/DX12, D3D12/DXGI, XAudio2, dan pustaka Windows lain. `sdk/runtime/gpu/d3d12.cpp` adalah backend produksi; `gpu/ext.h` masih mengekspos tipe D3D12 langsung. Guest memory juga mengasumsikan layout alamat tetap 4 GiB; probe pada iPhone menunjukkan alamat hint yang diminta tidak dipilih iOS. Audio Apple belum terintegrasi.

## Progress bertahap iOS

### Compile-check runtime (Selesai)
Target opsional `ios-game-runtime/` mengompilasi `input.cpp`, `log.cpp`, serta `ios_touch_controls.mm` terhadap iOS SDK dan SDL3 statis. Pemilihannya melalui `-DMC3_IOS_TARGET=game-runtime-check`. Job `ios-game-runtime-compile-check` pada workflow GitHub Actions berhasil memverifikasi komponen runtime dasar compatible dengan iOS SDK.

### UIKit app host (Selesai - Build CI Verified)
Target `ios-app/` membangun executable iOS dengan:
- Entry point `UIApplicationMain` menggantikan `wWinMain`
- `AppDelegate` dan `ViewController` untuk lifecycle iOS
- Touch overlay terintegrasi dari `ios_touch_controls.mm`
- Placeholder game loop menggunakan `CADisplayLink` (60fps display sync)
- `Info.plist` dengan landscape-only orientation dan status bar hidden
- SDL3 static library linked
- Logging menggunakan `logx::` namespace dan macro `LOGI/LOGE/LOGD`

Pemilihannya melalui `-DMC3_IOS_TARGET=ios-app`. Job workflow `ios-app-host` berhasil membangun dan package unsigned IPA (249 KB). Build verified di GitHub Actions macos-15 runner. App ini adalah foundation untuk integrasi renderer dan game logic, bukan game yang playable. Belum ditest di perangkat fisik atau simulator.

### Metal renderer basic (Selesai - Ready for CI)
Implementasi `MetalRenderer` class untuk clear-screen dengan animasi warna:
- `MetalRenderer.h` dan `MetalRenderer.mm` - C++ wrapper untuk Metal API
- Init membuat `MTLDevice` (GPU) dan command queue
- Draw render animated clear color cycling RGB spectrum (5s period)
- Terintegrasi ke `ViewController`: CAMetalLayer sebagai sublayer, render loop panggil `renderer->Draw()`
- Metal framework linked di CMakeLists.txt
- viewDidLayoutSubviews update drawable size saat rotation/resize

Ready untuk push dan CI verification. Setelah build sukses, app akan menampilkan layar animasi warna sebagai proof Metal pipeline berfungsi.

## Langkah berikutnya

1. **Verifikasi iOS app host di CI**: Jalankan job `ios-app-host` pada GitHub Actions dan perbaiki error build yang dilaporkan.
2. **Test di perangkat/simulator**: Deploy unsigned IPA ke iPhone atau iOS Simulator untuk memverifikasi app launch, touch overlay responsiveness, dan game loop berjalan.
3. **Rancang ulang guest memory**: Implementasikan memory layout portabel yang tidak bergantung pada fixed address `0x100000000` (iOS memilih `0x7000000000`). Uji allocation/translation sebelum integrasi penuh.
4. **Abstraksi GPU renderer**: Pisahkan `gpu/ext.h` dari tipe D3D12 spesifik. Buat interface abstrak untuk backend Metal.
5. **Implementasi Metal renderer bertahap**: Clear screen, draw test geometry, present. Uji setiap tahap sebelum menghubungkan game rendering penuh.
6. **Integrasikan game engine**: Hubungkan game initialization, main loop, dan shutdown dengan app lifecycle iOS (launch/resign active/terminate).
7. **Audio integration**: Hubungkan `audio_apple.mm` dengan game audio system; handle interruptions dan route changes.
8. **Platform services**: Filesystem access, threading/synchronization primitives iOS, exception handling Darwin-compatible.
9. **Device testing end-to-end**: Deploy ke perangkat fisik dengan konten yang sah distribusinya dan verifikasi gameplay.

## Verifikasi

Input virtual dan pemisahan vertex format telah diperiksa statis pada pekerjaan terdahulu. Backing store memori iOS, perubahan signature thread Darwin, dan audio Apple belum dikompilasi/diuji dengan Apple SDK menurut catatan audit sebelumnya. Workflow yang baru diubah belum dijalankan pada macOS CI. Kompilasi source saja tidak membuktikan runtime bekerja.

Windows masih dapat digunakan untuk meninjau source. Kompilasi iOS memerlukan runner macOS/Xcode; validasi akhir memerlukan perangkat iOS. Aset game dan kode hasil recompile tidak boleh dimasukkan ke repositori publik tanpa hak distribusi yang jelas.
