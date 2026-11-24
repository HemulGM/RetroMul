unit PS2.BIOS;

// A PlayStation 2 BIOS image (4 MiB) and the files in it. ROMDIR lists them
// (name, size of the file's extended information, file size). The files
// follow each other from the start of the image, 16-byte aligned; the first
// is RESET (the boot code) and ROMDIR itself comes right after it. ROMVER
// holds the version, the region letter, the console type and the build date.
// References: ps2tek (BIOS file structure).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, PS2.Types;

type
  TPS2BIOSFile = record
    Name: string;
    Offset, Size: Integer;
  end;

  TPS2BIOS = class
  private
    FImage: TBytes;
    FFiles: TArray<TPS2BIOSFile>;
    FROMVER: string;
    class function Scan(const Data: TBytes; out Files: TArray<TPS2BIOSFile>): Boolean; static;
  public
    // Raises EReadError unless Data is a 4 MiB image with a ROMDIR.
    constructor Create(const Data: TBytes);
    class function IsBIOS(const Data: TBytes): Boolean; static;
    function Find(const Name: string; out F: TPS2BIOSFile): Boolean;
    // The file's contents (nil when there is no such file).
    function ReadFile(const Name: string): TBytes;
    // The region letter of ROMVER: J (Japan), A (America), E (Europe),
    // H (Asia), R (Russia), C (China), T (devkit and test units).
    function RegionLetter: Char;
    property Image: TBytes read FImage;
    property Files: TArray<TPS2BIOSFile> read FFiles;
    // 'vvvvRCyyyymmdd': version (0190 for 1.90), region letter, console
    // type (C console, D devkit), build date.
    property ROMVER: string read FROMVER;
  end;

implementation

class function TPS2BIOS.Scan(const Data: TBytes; out Files: TArray<TPS2BIOSFile>): Boolean;
const
  Entry = 16;
begin
  Files := nil;
  if Length(Data) <> PS2BIOSSize then
    Exit(False);
  // ROMDIR starts with the RESET entry; RESET is the first file and ROMDIR
  // the second, so ROMDIR's offset is RESET's size rounded up to 16.
  var At := -1;
  for var P := 0 to $10000 - Entry do
    if (Data[P] = Ord('R')) and CompareMem(@Data[P], PAnsiChar('RESET'#0), 6) then
    begin
      At := P;
      Break;
    end;
  if At < 0 then
    Exit(False);
  var Offset := 0;
  var P := At;
  while P + Entry <= Length(Data) do
  begin
    if Data[P] = 0 then
      Break;
    var Name := '';
    for var K := 0 to 9 do
    begin
      if Data[P + K] = 0 then
        Break;
      Name := Name + Char(Data[P + K]);
    end;
    var Size := Integer(PCardinal(@Data[P + 12])^);
    if (Size < 0) or (Size > PS2BIOSSize) or (Int64(Offset) + Size > PS2BIOSSize) then
      Exit(False);
    var F: TPS2BIOSFile;
    F.Name := Name;
    F.Offset := Offset;
    F.Size := Size;
    Files := Files + [F];
    Offset := (Offset + Size + 15) and not 15;
    Inc(P, Entry);
  end;
  Result := (Length(Files) >= 2) and (Files[1].Name = 'ROMDIR') and (Files[1].Offset = At);
end;

class function TPS2BIOS.IsBIOS(const Data: TBytes): Boolean;
begin
  var Files: TArray<TPS2BIOSFile>;
  Result := Scan(Data, Files);
end;

constructor TPS2BIOS.Create(const Data: TBytes);
begin
  inherited Create;
  if not Scan(Data, FFiles) then
    raise EReadError.Create('Not a PlayStation 2 BIOS (4 MiB image with ROMDIR)');
  FImage := Copy(Data);
  var V := ReadFile('ROMVER');
  FROMVER := '';
  for var B in V do
  begin
    if (B < 32) or (B > 126) then
      Break;
    FROMVER := FROMVER + Char(B);
  end;
end;

function TPS2BIOS.Find(const Name: string; out F: TPS2BIOSFile): Boolean;
begin
  for var X in FFiles do
    if SameText(X.Name, Name) then
    begin
      F := X;
      Exit(True);
    end;
  Result := False;
end;

function TPS2BIOS.ReadFile(const Name: string): TBytes;
begin
  var F: TPS2BIOSFile;
  if not Find(Name, F) then
    Exit(nil);
  Result := Copy(FImage, F.Offset, F.Size);
end;

function TPS2BIOS.RegionLetter: Char;
begin
  if Length(FROMVER) >= 5 then
    Result := FROMVER[5]
  else
    Result := #0;
end;

end.
