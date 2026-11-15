A tribe strategy game where your people negotiate their tasks with you through an LLM, then carry them out on their own.

## Download

- **Windows (64-bit):** `EraOfSavagery-windows.zip` — unzip and run `EraOfSavagery.exe`.
- **macOS (Apple Silicon and Intel):** `EraOfSavagery-macos.zip` — unzip and open `Era of Savagery.app`.

## First launch

- The game isn't signed by a paid developer account, so your system will warn you once:
  - **Windows:** on the "Windows protected your PC" screen, click **More info → Run anyway**.
  - **macOS:** right-click the app and choose **Open**, then **Open** again. If macOS still refuses, go to **System Settings → Privacy & Security** and click **Open Anyway**, or run `xattr -dr com.apple.quarantine "Era of Savagery.app"` in Terminal.
- The first start builds the game's art from its 3D models. It takes about a minute and only happens once.
- The game plays fully offline. To let your tribespeople talk through a cloud LLM (DeepSeek or Zhipu GLM), open **LLM Settings** in the game and enter your own API key. It is stored only on your computer.

Requires a GPU with Vulkan (Windows) or Metal (macOS) support.
