<img width="303" height="84" alt="image" src="https://github.com/user-attachments/assets/36838464-6427-4387-9c4e-69dbab395bb3" />


# 🛠️ Development Environment Setup (Lazarus FPC)

This project is built using the **Lazarus IDE** and **Free Pascal Compiler (FPC)**. To compile and run the source code on your machine, please follow these setup instructions:

## 1. System Requirements
* **Lazarus IDE:** Version 2.2.0 or newer (Version 3.x is highly recommended).
* **FPC (Free Pascal Compiler):** Version 3.2.2 or newer.
* **Operating System:** Windows, Linux, or macOS (Cross-platform).

## 2. Package Installation
This project prioritizes native LCL components to remain lightweight. However, there is one essential external package required for the SMTP engine: **Indy (Internet Direct)**.

**How to Install Indy via OPM:**
1. Open Lazarus IDE.
2. Go to **Package** -> **Online Package Manager (OPM)**.
3. Type `Indy` in the search bar.
4. Check the **Indy10** package in the search results.
5. Click the **Install** button, then select **Install module**.
6. Lazarus will automatically rebuild and restart.

*(Note: For database connections, this application purely relies on Lazarus' built-in `SQLDB` components, so you do not need to install ZeosLib or any other additional packages).*

## 3. OpenSSL Libraries (Crucial!)
Because this application handles secure email delivery (SSL/TLS) and communicates with the Google Gemini API (HTTPS), you need OpenSSL libraries at **Runtime**.

1. Download the OpenSSL libraries version 1.0.2 or 1.1.1 (Matching your application's 32-bit or 64-bit architecture).
2. Extract the package and ensure the following files are present:
   * **Windows:** `libeay32.dll` and `ssleay32.dll` (or `libcrypto-1_1.dll` and `libssl-1_1.dll`).
   * **Linux:** `libssl.so` and `libcrypto.so`.
3. Place these library files in the **same folder (side-by-side)** with your executable file (e.g., `PasMail.exe`).

## 4. How to Build the Project
1. Open the main project file (`.lpi`) in Lazarus.
2. Go to **Project** -> **Project Options** -> **Compiler Options**.
3. Ensure the target architecture matches your system (e.g., `Win64`).
4. Press **F9** (Run) or **Ctrl+F9** (Build) to start compiling.
5. Upon the first run, the application will automatically create the `db` folder, `logs` folder, and `config.ini` file in the same directory as the executable.

---
### 💡 Multithreading Debugging Note
If you are debugging (F9) through the Lazarus IDE and encounter an `EConvertError` or *Database is Locked* notification, this is often just an internal debugger interruption when the IDE context-switches between threads. 

To test its maximum stability and performance, run the compiled executable file (`.exe`) directly outside the IDE.
