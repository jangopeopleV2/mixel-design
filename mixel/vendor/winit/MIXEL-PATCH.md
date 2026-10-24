MIXEL Mac App Store compatibility patch

Baseline: winit 0.30.13, Apache-2.0 (unmodified LICENSE retained).
Design retains the complete fork at 3d51077fd1a966f84df9ef287839dc84fd5b4ca7 and its termination behavior.

Modified 2026-10-24: only src/platform_impl/macos/ffi.rs and window_delegate.rs change. Remove the private CGS blur declarations and make optional background blur unsupported. Ordinary window rendering and all other platforms retain their implementation.

Apple guideline 2.5.1 rejects CGSSetWindowBackgroundBlurRadius. Related upstream issue: https://github.com/rust-windowing/winit/issues/4205
Upstream gates private Apple APIs in the 0.31 development line: https://github.com/rust-windowing/winit/pull/4541
This patch avoids a renderer/windowing major-version migration.

The MAS packaging helper scans actual Mach-O binaries for both forbidden symbols.
