unit Core.Storage.Types;

interface

uses System.SysUtils, System.Classes, System.IniFiles;

type
  TStorageFile = record
    Name, Location, RelativePath: string;
    Size: Int64;
  end;

  TStorageSnapshot = record
    Name, Location, PreviewLocation: string;
    Modified: TDateTime;
  end;

  TStorageSelection = record
    Cancelled: Boolean;
    Location, Error: string;
  end;

  TStorageSelectionCallback = reference to procedure(const Selection: TStorageSelection);

  IStoragePicker = interface
    ['{5C59D789-BB3D-4E67-90B2-DF36C33C8488}']
    procedure Select(Folder: Boolean; const Callback: TStorageSelectionCallback);
  end;

  IStorage = interface
    ['{93F9CA56-A0BB-45A0-BBD2-F907BAF8CDA1}']
    function GetRoot: string;
    function RomFolder(const SystemId: string): string;
    procedure SetRomFolder(const SystemId, Value: string);
    function DetectRomFolder(const Location, SystemId: string): string;
    function GetCheckRomFileSize: Boolean;
    procedure SetCheckRomFileSize(Value: Boolean);
    function GetMaxRomFileSize: Int64;
    procedure SetMaxRomFileSize(Value: Int64);
    function OpenRead(const Location: string): TStream;
    function OpenWrite(const Location: string): TStream;
    function Exists(const Location: string): Boolean;
    function ModifiedTime(const Location: string): TDateTime;
    function FolderExists(const Location: string): Boolean;
    procedure EnsureFolder(const Location: string);
    function Files(const Location: string; Recursive: Boolean = False): TArray<string>;
    function Folders(const Location: string): TArray<string>;
    procedure Delete(const Location: string);
    procedure Replace(const Source, Target: string);
    procedure WriteAtomic(const Location: string; Stream: TStream);
    function ReadBytes(const Location: string): TBytes;
    procedure WriteBytes(const Location: string; const Data: TBytes);
    function ReadText(const Location: string): string;
    function ConfigFile(const SystemId: string): string;
    function ReadConfig(const Location: string): TMemIniFile;
    procedure WriteConfig(Ini: TMemIniFile);
    function SaveRoot: string;
    function SnapshotRoot: string;
    function ScreenshotFile(const RomName: string): string;
    function TemporaryFile(const Extension: string): string;
    function GamePath(const Root, RomName, Identity, Extension: string): string;
    function GameSave(const SystemId, RomName, Identity: string): string;
    function GameSnapshots(const SystemId, RomName, Identity: string): string;
    function Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
    function Roms(const SystemId: string): TArray<TStorageFile>;
    function Describe(const Location: string): TStorageFile;
    procedure SelectRom(const Callback: TStorageSelectionCallback);
    property Root: string read GetRoot;
    // Listing filter only; file contents are never read to check the size.
    property CheckRomFileSize: Boolean read GetCheckRomFileSize write SetCheckRomFileSize;
    property MaxRomFileSize: Int64 read GetMaxRomFileSize write SetMaxRomFileSize;
  end;


implementation

end.
