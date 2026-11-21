# Status Port iOS — MC3 Xbox Recomp

Dokumen ini mencatat hasil audit dan perubahan port yang sudah ada. Ini bukan klaim bahwa aplikasi iOS sudah bisa dibangun atau dimainkan.

## Fondasi yang sudah ditambahkan

- `sdk/runtime/core/input.h` dan `input.cpp` menyediakan `VirtualControl`, `SetVirtualControl`, dan `OnScancode` untuk input host non-keyboard. Kontrol virtual diterjemahkan ke laporan pad Xbox pada port 0. Keyboard fallback SDL kini tidak membuat controller sintetis tersambung permanen pada target iOS; kontrol sentuh/virtual tetap dapat menyambungkan laporan saat digunakan.
- `sdk/runtime/app/ios_touch_controls.h` dan `.mm` menyediakan overlay UIKit awal dengan tombol arah, tombol muka, shoulder, Back, dan Start yang meneruskan press/release ke `SetVirtualControl`. Deklarasi dan implementasi UIKit kini dibatasi ke `TARGET_OS_IPHONE` agar tidak ikut terkompilasi pada target Apple non-iOS. Overlay belum dipanggil host app dan belum masuk build.
- `sdk/runtime/audio/audio_apple.mm` berisi implementasi awal output stereo float melalui Audio Queue Services untuk Apple. File ini belum dimasukkan ke target CMake dan belum dikompilasi atau diuji.

Overlay touch ini hanya komponen sumber, bukan app iOS atau jalur input yang sudah berjalan. Game view, lifecycle UIKit dan target Apple belum tersedia.

## Langkah kerja berikutnya

1. Jalankan workflow `.github/workflows/ios-build.yml` atau build `MC3MemoryProbe` di macOS dengan Xcode/iOS SDK; workflow menghasilkan bundle diagnostik unsigned, yang perlu ditandatangani untuk pemasangan biasa ke iPhone. Jalankan di iPhone dan rekam hasil reservasi/alignment/alias serta siklus commit/discard/decommit/recommit.
2. Jika probe lulus, uji memory pressure dan siklus commit/decommit berulang pada beberapa versi iOS dan perangkat; jika gagal, tentukan alternatif guest-address translation sebelum port host.
3. Setelah memory gate, pisahkan build host platform pada CMake tanpa mengubah jalur Windows yang sudah ada.
4. Buat app shell UIKit/MetalKit dan jalur lifecycle untuk boot/pause/resume/stop runtime.
5. Audit portabilitas filesystem, thread/sinkronisasi, exception handling dan networking.
6. Lepaskan kontrak GPU extension dari tipe D3D12 sebelum mengimplementasikan renderer Metal; jangan memakai stub renderer yang melaporkan sukses tanpa menggambar.
7. Integrasikan Audio Queue dengan kepemilikan dan shutdown eksplisit serta sesi audio iOS.
8. Bangun di macOS/Xcode, perbaiki error kompilasi, lalu uji di iPhone sebelum menyebut IPA siap dipasang.

Target probe memang terpisah dari game dan tidak berisi aset game. Untuk mengonfigurasi, gunakan root CMake dengan iOS toolchain; lihat `ios-memory-probe/README.md`. Root CMake mengarahkan target iOS ke probe, bukan game.

Windows dapat dipakai untuk mengerjakan dan meninjau source. Kompilasi IPA dan validasi device memerlukan runner macOS/Xcode serta perangkat iOS untuk uji akhir.

## Hambatan utama yang masih terbuka

Probe memori mandiri tersedia di `sdk/runtime/kernel/ios_memory_probe.mm` dan menjadi app `MC3MemoryProbe`; probe kini mencakup reservasi 4 GiB, dua alias shared, serta satu siklus guest-page commit/discard/decommit/recommit yang mengikuti urutan POSIX di `memory.cpp`. Probe belum dibangun atau dijalankan. Hasilnya merupakan gate awal saja: jika lulus pada satu perangkat, tetap perlu uji beberapa kelas perangkat/iOS dan stress test sebelum menganggap layout aman.

- `sdk/cmake/XbeRecomp.cmake` tetap hanya membuat executable Win32, memakai ImGui Win32/DX12, D3D12/DXGI, XAudio2 dan Windows libraries.
- `sdk/runtime/app/main.cpp` masih entry point `wWinMain`, mengelola Win32 window/message loop, file discovery, settings, splash, handover, crash dump dan boot.
- `sdk/runtime/gpu/d3d12.cpp` adalah backend grafis produksi yang sangat besar. `gpu::Backend` adalah seam yang dapat dipakai untuk backend Metal, tetapi banyak extension juga bergantung langsung pada tipe D3D12 di `gpu/ext.h`.
- Vertex assembly kini memakai `HostFormat` backend-neutral, dan D3D12 memetakannya saat membangun input layout. Ini hanya memisahkan format vertex; cache pipeline, extension API, shader dan renderer tetap D3D12-specific.
- Kernel/runtime memiliki ketergantungan Win32 untuk alokasi memori guest, thread/sinkronisasi, file/disc dan operasi sistem lainnya. `kernel/memory.cpp` kini memakai file sementara dalam temporary directory sandbox yang langsung di-unlink sebagai backing store pada iOS, bukan Linux-only `memfd_create`; Linux tetap memakai `memfd_create` dan `MAP_NORESERVE`. `kernel/threads.cpp` kini memakai pemanggilan `pthread_setname_np` sesuai signature Darwin, sementara host POSIX lain tetap memakai signature yang ada. Kedua perubahan hanya ditinjau secara statis, belum dikompilasi dengan Apple SDK. Reservasi 4 GB pada alamat tetap dan dua alias pemetaan fisik tetap belum terbukti dapat dipenuhi iOS.
إن- Audio Apple baru scaffold. Lifecycle start/stop, interupsi, route perubahan perangkat, real-time safety dan error recovery belum dituntaskan.
- Belum tersedia target game Xcode/iOS, host iOS/Metal, HUD sentuh terintegrasi, bundling aset yang aman, atau IPA. `ios-memory-probe/` kini berisi target aplikasi diagnostik UIKit mandiri yang memanggil `sdk/runtime/kernel/ios_memory_probe.mm`; konfigurasi iOS di root diarahkan ke target ini dan tidak mencoba membangun game. Belum dikonfigurasi atau dijalankan dengan Xcode/perangkat.

## Status verifikasi

Input virtual diperiksa statis untuk konsistensi deklarasi/definisi dan posisi tombol laporan yang terdokumentasi di `Pad`; jalur keyboard SDL kini dikondisikan untuk platform non-iOS. Backing store memori iOS diperiksa statis untuk cleanup file-descriptor dan unmap saat kegagalan; tidak dikompilasi atau diuji pada Apple. Pemisahan vertex format diperiksa statis saja; tidak ada build atau uji runtime. Audio Apple tidak diverifikasi dengan toolchain Apple. Aset game dan kode hasil recompile tidak boleh dimasukkan ke repositori publik tanpa hak distribusi yang jelas.
