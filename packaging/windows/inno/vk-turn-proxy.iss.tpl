#define AppName "VK Turn Proxy"
#define AppPublisher "VK Turn Proxy"
#define AppVersion "{APP_VERSION}"
#define SourceDir "{SOURCE_DIR}"
#define OutputDir "{OUTPUT_DIR}"
#define InstallerBaseName "{INSTALLER_BASE_NAME}"

[Setup]
AppId={{9E0768E4-FCF8-4BEF-8F1D-789C8D3E54E3}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\VKTurnProxy
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\README-WINDOWS.txt
OutputDir={#OutputDir}
OutputBaseFilename={#InstallerBaseName}
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
WizardStyle=modern
UninstallDisplayIcon={app}\desktopApp\bin\desktopApp.bat

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\VK Turn Proxy"; Filename: "{app}\desktopApp\bin\desktopApp.bat"; WorkingDir: "{app}\desktopApp"
Name: "{group}\Install Tunnel Service"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\install-service.ps1"""; WorkingDir: "{app}"
Name: "{group}\Start Tunnel"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\start-tunnel.ps1"""; WorkingDir: "{app}"
Name: "{group}\Tunnel Status"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\status-tunnel.ps1"""; WorkingDir: "{app}"
Name: "{group}\Stop Tunnel"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\stop-tunnel.ps1"""; WorkingDir: "{app}"
Name: "{group}\Export Logs"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\export-logs.ps1"""; WorkingDir: "{app}"
Name: "{group}\Uninstall Tunnel Service"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall-service.ps1"""; WorkingDir: "{app}"

[Run]
Filename: "{app}\desktopApp\bin\desktopApp.bat"; Description: "Launch VK Turn Proxy"; Flags: nowait postinstall skipifsilent unchecked

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{app}\uninstall-service.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "UninstallVKTurnProxyTunnelService"
