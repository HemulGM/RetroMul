unit PSP.Utility;

interface

uses
  System.SysUtils, Core.Emulation.Types, PSP.Memory, PSP.CPU, PSP.FileSystem;

type
  TPSPUtility = class
  private
    FMemory: TPSPMemory;
    FCPU: TPSPCPU;
    FFiles: TPSPFileSystem;
    FSaveAddress, FSaveStatus: Cardinal;
    FSaveChoices: TArray<string>;
    FSaveChoice: Integer;
    FSaveList, FSaveSelected: Boolean;
    FAddress, FStatus, FOptions, FSelection: Cardinal;
    FText: string;
    FPrevious: TEmulatorButtons;
    FOskAddress, FOskStatus, FOskField, FOskSelection: Cardinal;
    FOskText, FOskInitialText: string;
    function OskFieldAddress: Cardinal;
    procedure LoadOskField;
    procedure FinishOskField(Cancelled: Boolean);
    procedure Savedata;
    function SaveMetadata(const DirectoryName: string): TBytes;
  public
    constructor Create(Memory: TPSPMemory; CPU: TPSPCPU; Files: TPSPFileSystem);
    function Handle(NID: Cardinal; out Value: Cardinal): Boolean;
    procedure Update(const Input: TEmulatorInput);
    procedure Render(var Frame: TEmulatorFrame);
    function Visible: Boolean;
  end;

implementation

uses
  System.IOUtils, System.Classes, System.DateUtils, System.Math,
  System.Generics.Collections, PSP.Media;

constructor TPSPUtility.Create(Memory: TPSPMemory; CPU: TPSPCPU; Files: TPSPFileSystem);
begin
  inherited Create;
  FMemory := Memory;
  FCPU := CPU;
  FFiles := Files;
end;

function TPSPUtility.SaveMetadata(const DirectoryName: string): TBytes;
var
  Keys, Values, Entries: TBytes;

  procedure Put(var Data: TBytes; Offset: Integer; Value: Cardinal; Size: Integer = 4);
  begin
    for var I := 0 to Size - 1 do
      Data[Offset + I] := (Value shr (I * 8)) and $FF;
  end;

  procedure Add(const Name: string; Format: Word; const Bytes: TBytes; Capacity: Integer);
  begin
    var Offset := Length(Entries);
    SetLength(Entries, Offset + 16);
    Put(Entries, Offset, Length(Keys), 2);
    Put(Entries, Offset + 2, Format, 2);
    Put(Entries, Offset + 4, Length(Bytes));
    Put(Entries, Offset + 8, Capacity);
    Put(Entries, Offset + 12, Length(Values));
    Keys := Keys + TEncoding.ASCII.GetBytes(Name + #0);
    var At := Length(Values);
    SetLength(Values, At + Capacity);
    if Length(Bytes) > Capacity then
      raise EPSPFormat.Create('PSP: savedata metadata exceeds field capacity');
    if Length(Bytes) > 0 then
      Move(Bytes[0], Values[At], Length(Bytes));
  end;

begin
  Add('CATEGORY', $0204, TEncoding.UTF8.GetBytes('MS'#0), 4);
  var Level: TBytes;
  SetLength(Level, 4);
  Level[0] := FMemory.Read8(FSaveAddress + 1408);
  Add('PARENTAL_LEVEL', $0404, Level, 4);
  Add('SAVEDATA_DETAIL', $0204, TEncoding.UTF8.GetBytes(FMemory.ReadString(FSaveAddress + 384, 1024) + #0), 1024);
  Add('SAVEDATA_DIRECTORY', $0204, TEncoding.UTF8.GetBytes(DirectoryName + #0), 64);
  var Params: TBytes;
  SetLength(Params, 128);
  Add('SAVEDATA_PARAMS', $0004, Params, 128);
  Add('SAVEDATA_TITLE', $0204, TEncoding.UTF8.GetBytes(FMemory.ReadString(FSaveAddress + 256, 128) + #0), 128);
  Add('TITLE', $0204, TEncoding.UTF8.GetBytes(FMemory.ReadString(FSaveAddress + 128, 128) + #0), 128);
  var KeyBase := 20 + Length(Entries);
  var ValueBase := (KeyBase + Length(Keys) + 3) and not 3;
  SetLength(Result, ValueBase + Length(Values));
  Put(Result, 0, $46535000);
  Put(Result, 4, $101);
  Put(Result, 8, KeyBase);
  Put(Result, 12, ValueBase);
  Put(Result, 16, Length(Entries) div 16);
  Move(Entries[0], Result[20], Length(Entries));
  Move(Keys[0], Result[KeyBase], Length(Keys));
  Move(Values[0], Result[ValueBase], Length(Values));
end;

procedure TPSPUtility.Savedata;

  procedure WriteDate(Address: Cardinal; Value: TDateTime);
  var
    Y, M, D, H, N, S, MS: Word;
  begin
    DecodeDateTime(Value, Y, M, D, H, N, S, MS);
    FMemory.Write16(Address, Y);
    FMemory.Write16(Address + 2, M);
    FMemory.Write16(Address + 4, D);
    FMemory.Write16(Address + 6, H);
    FMemory.Write16(Address + 8, N);
    FMemory.Write16(Address + 10, S);
    FMemory.Write32(Address + 12, Cardinal(MS) * 1000);
  end;

  function FixedName(Address, Capacity: Cardinal): string;
  begin
    var Bytes := FMemory.ReadBytes(Address, Capacity);
    var Count := 0;
    while (Count < Length(Bytes)) and (Bytes[Count] <> 0) do
      Inc(Count);
    Result := TEncoding.UTF8.GetString(Bytes, 0, Count);
  end;

  function Match(const Name, Pattern: string): Boolean;
  begin
    var N := 1;
    var P := 1;
    var Star := 0;
    var Retry := 0;
    while N <= Length(Name) do
    begin
      if (P <= Length(Pattern)) and ((Pattern[P] = '?') or (UpCase(Pattern[P]) = UpCase(Name[N]))) then
      begin
        Inc(N);
        Inc(P)
      end
      else if (P <= Length(Pattern)) and (Pattern[P] = '*') then
      begin
        Star := P;
        Inc(P);
        Retry := N
      end
      else if Star <> 0 then
      begin
        P := Star + 1;
        Inc(Retry);
        N := Retry
      end
      else
        Exit(False);
    end;
    while (P <= Length(Pattern)) and (Pattern[P] = '*') do
      Inc(P);
    Result := P > Length(Pattern);
  end;

begin
  var A := FSaveAddress;
  var Mode := FMemory.Read32(A + 48);
  var Game := FMemory.ReadString(A + 60, 13);
  var Save := FMemory.ReadString(A + 76, 20);
  if Save = '<>' then
    Save := '';
  var FileName := FMemory.ReadString(A + 100, 13);
  for var Name in [Game, Save, FileName] do
    if Name.Contains('/') or Name.Contains('\') or Name.Contains(':') or Name.Contains('..') then
      raise EPSPInstruction.Create('PSP: invalid savedata path component');
  if Mode in [4, 5] then
  begin
    if not FSaveSelected then
    begin
      if FSaveList then
        Exit;
      FSaveChoices := nil;
      FSaveChoice := 0;
      var Root := FFiles.MemoryStickPath('ms0:/PSP/SAVEDATA');
      var Names := FMemory.Read32(A + 96);
      if Names <> 0 then
      begin
        for var I := 0 to 4095 do
        begin
          if not FMemory.IsValid(Names + Cardinal(I) * 20, 20) then
          begin
            FMemory.Write32(A + 28, $80110308);
            FSaveStatus := 3;
            Exit
          end;
          var Name := FixedName(Names + Cardinal(I) * 20, 20);
          if Name = '' then
            Break;
          if Name.Contains('/') or Name.Contains('\') or Name.Contains(':') or Name.Contains('..') then
          begin
            FMemory.Write32(A + 28, $80110308);
            FSaveStatus := 3;
            Exit
          end;
          if (Mode = 5) or TDirectory.Exists(TPath.Combine(Root, Game + Name)) then
            FSaveChoices := FSaveChoices + [Name];
        end;
      end
      else if TDirectory.Exists(Root) then
      begin
        var Directories := TDirectory.GetDirectories(Root);
        TArray.Sort<string>(Directories);
        var Pattern := Save;
        if Pattern = '' then
          Pattern := '*';
        for var Directory in Directories do
        begin
          var Name := TPath.GetFileName(Directory);
          if Match(Name, Game + Pattern) then
            FSaveChoices := FSaveChoices + [Name.Substring(Length(Game))];
        end;
      end;
      if (Mode = 5) and (Length(FSaveChoices) = 0) then
        FSaveChoices := FSaveChoices + [Save];
      if Length(FSaveChoices) = 0 then
      begin
        FMemory.Write32(A + 28, $80110307);
        FSaveStatus := 3;
        Exit
      end;
      for var I := 0 to High(FSaveChoices) do
        if SameText(FSaveChoices[I], Save) then
          FSaveChoice := I;
      FSaveList := True;
      Exit;
    end;
    Save := FSaveChoices[FSaveChoice];
    if Mode = 4 then
      Mode := 0
    else
      Mode := 1;
  end;
  var Folder := FFiles.MemoryStickPath('ms0:/PSP/SAVEDATA/' + Game + Save);
  var Path := TPath.Combine(Folder, FileName);
  var ResultCode: Cardinal := 0;
  if (Mode in [11, 12, 22]) and (FMemory.Read32(A) < 1536) then
  begin
    FMemory.Write32(A + 28, $80110385);
    FSaveStatus := 3;
    Exit
  end;
  case Mode of
    11:
      begin
        var Info := FMemory.Read32(A + 1524);
        if (Info = 0) or not FMemory.IsValid(Info, 12) then
        begin
          FMemory.Write32(A + 28, $80110385);
          FSaveStatus := 3;
          Exit
        end;
        var Capacity := FMemory.Read32(Info);
        var Entries := FMemory.Read32(Info + 8);
        if (Capacity > 4096) or ((Capacity <> 0) and not FMemory.IsValid(Entries, Capacity * 72)) then
        begin
          FMemory.Write32(A + 28, $80110385);
          FSaveStatus := 3;
          Exit
        end;
        var Count: Cardinal := 0;
        var Root := FFiles.MemoryStickPath('ms0:/PSP/SAVEDATA');
        if TDirectory.Exists(Root) then
          for var Directory in TDirectory.GetDirectories(Root) do
          begin
            if Count >= Capacity then
              Break;
            var Name := TPath.GetFileName(Directory);
            if not Match(Name, Game + Save) then
              Continue;
            var Entry := Entries + Count * 72;
            FMemory.Zero(Entry, 72);
            FMemory.Write32(Entry, $11FF);
            var Metadata := TPath.Combine(Directory, 'PARAM.SFO');
            if TFile.Exists(Metadata) then
            begin
              WriteDate(Entry + 4, TFile.GetCreationTime(Metadata));
              WriteDate(Entry + 20, TFile.GetLastAccessTime(Metadata));
              WriteDate(Entry + 36, TFile.GetLastWriteTime(Metadata));
            end
            else
            begin
              WriteDate(Entry + 4, TDirectory.GetCreationTime(Directory));
              WriteDate(Entry + 20, TDirectory.GetLastAccessTime(Directory));
              WriteDate(Entry + 36, TDirectory.GetLastWriteTime(Directory));
            end;
            FMemory.Load(Entry + 52, Copy(TEncoding.UTF8.GetBytes(Name.Substring(Length(Game))), 0, 19));
            Inc(Count);
          end;
        FMemory.Write32(Info + 4, Count);
      end;
    12:
      begin
        var Info := FMemory.Read32(A + 1528);
        if not FMemory.IsValid(Info, 36) then
        begin
          FMemory.Write32(A + 28, $80110385);
          FSaveStatus := 3;
          Exit
        end;
        for var I := 0 to 2 do
          FMemory.Write32(Info + 12 + Cardinal(I) * 4, 0);
        if not TDirectory.Exists(Folder) then
          ResultCode := $801103C7
        else if not TFile.Exists(TPath.Combine(Folder, 'PARAM.SFO')) then
          ResultCode := $801103C6
        else
        begin
          FMemory.Write32(A + 52, 1021);
          for var Item in TDirectory.GetFiles(Folder) do
          begin
            var Name := TPath.GetFileName(Item);
            if Name <> UpperCase(Name) then
              Continue;
            var Group: Cardinal := 1;
            if (Name = 'PARAM.SFO') or (Name = 'ICON0.PNG') or (Name = 'ICON1.PMF') or (Name = 'PIC1.PNG') or (Name = 'SND0.AT3') then
              Group := 2;
            var Capacity := FMemory.Read32(Info + Group * 4);
            var Count := FMemory.Read32(Info + 12 + Group * 4);
            if Count >= Capacity then
              Continue;
            var Entries := FMemory.Read32(Info + 24 + Group * 4);
            if (Capacity > 4096) or not FMemory.IsValid(Entries, Capacity * 80) then
            begin
              ResultCode := $80110385;
              Break
            end;
            var Entry := Entries + Count * 80;
            FMemory.Zero(Entry, 80);
            FMemory.Write32(Entry, $21FF);
            var FileSize := TFile.GetSize(Item);
            FMemory.Write32(Entry + 8, Cardinal(FileSize));
            FMemory.Write32(Entry + 12, Cardinal(UInt64(FileSize) shr 32));
            WriteDate(Entry + 16, TFile.GetCreationTime(Item));
            WriteDate(Entry + 32, TFile.GetLastAccessTime(Item));
            WriteDate(Entry + 48, TFile.GetLastWriteTime(Item));
            FMemory.Load(Entry + 64, Copy(TEncoding.UTF8.GetBytes(Name), 0, 15));
            FMemory.Write32(Info + 12 + Group * 4, Count + 1);
          end;
        end;
      end;
    22:
      begin
        var Info := FMemory.Read32(A + 1532);
        if not FMemory.IsValid(Info, 60) then
        begin
          FMemory.Write32(A + 28, $80110385);
          FSaveStatus := 3;
          Exit
        end;
        var WriteBytes: UInt64 := 0;
        var OldBytes: UInt64 := 0;
        for var Group := 0 to 1 do
        begin
          var Count := FMemory.Read32(Info + Cardinal(Group) * 4);
          var Entries := FMemory.Read32(Info + 8 + Cardinal(Group) * 4);
          if (Count > 4096) or ((Count <> 0) and not FMemory.IsValid(Entries, Count * 24)) then
          begin
            ResultCode := $80110385;
            Break
          end;
          for var I := 0 to Integer(Count) - 1 do
          begin
            var Entry := Entries + Cardinal(I) * 24;
            var Size := UInt64(FMemory.Read32(Entry)) or (UInt64(FMemory.Read32(Entry + 4)) shl 32);
            if (WriteBytes > High(UInt64) - 16) or (Size > High(UInt64) - WriteBytes - 16) then
            begin
              ResultCode := $80110385;
              Break
            end;
            Inc(WriteBytes, Size);
            if Group = 0 then
              Inc(WriteBytes, 16);
            var Name := FixedName(Entry + 8, 16);
            if Name.Contains('/') or Name.Contains('\') or Name.Contains(':') or Name.Contains('..') then
            begin
              ResultCode := $80110385;
              Break
            end;
            var Existing := TPath.Combine(Folder, Name);
            if TFile.Exists(Existing) then
              Inc(OldBytes, TFile.GetSize(Existing));
          end;
        end;
        if ResultCode = 0 then
        begin
          const FreeBytes: UInt64 = UInt64(2) * 1024 * 1024 * 1024;
          FMemory.Write32(Info + 16, 32768);
          FMemory.Write32(Info + 20, 65536);
          FMemory.Write32(Info + 24, 2097152);
          FMemory.Zero(Info + 28, 8);
          FMemory.Load(Info + 28, TEncoding.ASCII.GetBytes('2 GB'#0));
          FMemory.Write32(Info + 36, 0);
          FMemory.Write32(Info + 48, 0);
          if (WriteBytes > FreeBytes) and (WriteBytes - FreeBytes > OldBytes) then
          begin
            var Needed := Min(UInt64(High(Cardinal)), (WriteBytes - FreeBytes) div 1024 + UInt64(Ord((WriteBytes - FreeBytes) mod 1024 <> 0)));
            FMemory.Write32(Info + 36, Needed);
            FMemory.Zero(Info + 40, 8);
            FMemory.Load(Info + 40, Copy(TEncoding.ASCII.GetBytes(UIntToStr(Needed) + ' KB'#0), 0, 7));
            if WriteBytes > FreeBytes + OldBytes then
            begin
              var Overwrite := Min(UInt64(High(Cardinal)), (WriteBytes - FreeBytes - OldBytes) div 1024 + UInt64(Ord((WriteBytes - FreeBytes - OldBytes) mod 1024 <> 0)));
              FMemory.Write32(Info + 48, Overwrite);
              FMemory.Zero(Info + 52, 8);
              FMemory.Load(Info + 52, Copy(TEncoding.ASCII.GetBytes(UIntToStr(Overwrite) + ' KB'#0), 0, 7));
            end;
          end;
          if not TDirectory.Exists(Folder) then
            ResultCode := $801103C7;
        end;
      end;
    1, 3, 14, 18:
      begin
        var Buffer := FMemory.Read32(A + 116);
        var Capacity := FMemory.Read32(A + 120);
        var Size := FMemory.Read32(A + 124);
        if (Size > Capacity) or not FMemory.IsValid(Buffer, Size) then
          ResultCode := $80110388
        else
        begin
          TDirectory.CreateDirectory(Folder);
          var Data: TBytes;
          Data := FMemory.ReadBytes(Buffer, Size);
          TFile.WriteAllBytes(Path + '.retromul-tmp', Data);
          if TFile.Exists(Path) then
          begin
            var Backup := Path + '.retromul-backup';
            if TFile.Exists(Backup) then
              TFile.Delete(Backup);
            TFile.Replace(Path + '.retromul-tmp', Path, Backup);
            TFile.Delete(Backup);
          end
          else
            TFile.Move(Path + '.retromul-tmp', Path);
          TFile.WriteAllBytes(TPath.Combine(Folder, 'PARAM.SFO'), SaveMetadata(Game + Save));
          for var I := 0 to 3 do
          begin
            var Item := A + 1412 + Cardinal(I) * 16;
            var AssetSize := FMemory.Read32(Item + 8);
            if AssetSize = 0 then
              Continue;
            if AssetSize > FMemory.Read32(Item + 4) then
              raise EPSPFormat.Create('PSP: savedata asset exceeds buffer');
            var Source := FMemory.Read32(Item);
            if not FMemory.IsValid(Source, AssetSize) then
              raise EPSPFormat.Create('PSP: invalid savedata asset buffer');
            Data := FMemory.ReadBytes(Source, AssetSize);
            var AssetName: string;
            case I of
              0:
                AssetName := 'ICON0.PNG';
              1:
                AssetName := 'ICON1.PMF';
              2:
                AssetName := 'PIC1.PNG';
            else
              AssetName := 'SND0.AT3';
            end;
            TFile.WriteAllBytes(TPath.Combine(Folder, AssetName), Data);
          end;
        end;
      end;
    0, 2, 15, 16:
      if not TDirectory.Exists(Folder) then
        ResultCode := $80110307
      else if not TFile.Exists(Path) then
        ResultCode := $80110309
      else
      begin
        var Buffer := FMemory.Read32(A + 116);
        var Capacity := FMemory.Read32(A + 120);
        var Data := TFile.ReadAllBytes(Path);
        if (Cardinal(Length(Data)) > Capacity) or not FMemory.IsValid(Buffer, Length(Data)) then
          ResultCode := $80110308
        else
        begin
          FMemory.Load(Buffer, Data);
          FMemory.Write32(A + 124, Length(Data));
        end;
      end;
    8:
      begin
        if FMemory.Read32(A) < 1500 then
          raise EPSPFormat.Create('PSP: savedata sizes requires extended parameters');
        var Free := FMemory.Read32(A + 1488);
        if Free <> 0 then
        begin
          FMemory.Zero(Free, 20);
          FMemory.Write32(Free, 32768);
          FMemory.Write32(Free + 4, 65536);
          FMemory.Write32(Free + 8, 2097152);
          FMemory.Load(Free + 12, TEncoding.ASCII.GetBytes('2 GB'#0));
        end;
        var Data := FMemory.Read32(A + 1492);
        if Data <> 0 then
        begin
          FMemory.Zero(Data + 36, 28);
          if not TDirectory.Exists(Folder) then
            ResultCode := $801103C7;
        end;
        var Used := FMemory.Read32(A + 1496);
        if Used <> 0 then
        begin
          var Clusters := 2 + (UInt64(FMemory.Read32(A + 124)) + 32767) div 32768;
          FMemory.Zero(Used, 28);
          FMemory.Write32(Used, Clusters);
          FMemory.Write32(Used + 4, Clusters * 32);
          FMemory.Load(Used + 8, TEncoding.ASCII.GetBytes(UIntToStr(Clusters * 32) + ' KB'#0));
          FMemory.Write32(Used + 16, Clusters * 32);
          FMemory.Load(Used + 20, TEncoding.ASCII.GetBytes(UIntToStr(Clusters * 32) + ' KB'#0));
        end;
      end;
  else
    raise EPSPInstruction.CreateFmt('PSP: savedata mode %d is not implemented', [Mode]);
  end;
  FMemory.Write32(A + 28, ResultCode);
  FSaveStatus := 3;
end;

function TPSPUtility.OskFieldAddress: Cardinal;
begin
  Result := FMemory.Read32(FOskAddress + 52) + FOskField * 52
end;

procedure TPSPUtility.LoadOskField;
begin
  FOskText := '';
  FOskInitialText := '';
  FOskSelection := 0;
  var Field := OskFieldAddress;
  var Initial := FMemory.Read32(Field + 32);
  var Limit := FMemory.Read32(Field + 36) - 1;
  if FMemory.Read32(Field + 48) <> 0 then
    Limit := Min(Limit, FMemory.Read32(Field + 48));
  if Initial = 0 then
    Exit;
  for var I := 0 to Integer(Limit) - 1 do
  begin
    if not FMemory.IsValid(Initial + Cardinal(I) * 2, 2) then
      Break;
    var C := FMemory.Read16(Initial + Cardinal(I) * 2);
    if C = 0 then
      Break;
    FOskText := FOskText + Char(C);
  end;
  FOskInitialText := FOskText;
end;

procedure TPSPUtility.FinishOskField(Cancelled: Boolean);
begin
  var Field := OskFieldAddress;
  var Output := FMemory.Read32(Field + 40);
  if Cancelled then
    FMemory.Write32(Field + 44, 1)
  else
  begin
    FMemory.Write32(Field + 44, 2 * Ord(FOskText <> FOskInitialText));
    for var I := 1 to Length(FOskText) do
      FMemory.Write16(Output + Cardinal(I - 1) * 2, Ord(FOskText[I]));
    FMemory.Write16(Output + Cardinal(Length(FOskText)) * 2, 0);
  end;
  Inc(FOskField);
  if not Cancelled and (FOskField < FMemory.Read32(FOskAddress + 48)) then
    LoadOskField
  else
  begin
    FOskStatus := 3;
    FMemory.Write32(FOskAddress + 56, 4);
    FMemory.Write32(FOskAddress + 28, 0);
  end;
end;

function TPSPUtility.Visible: Boolean;
begin
  Result := (FStatus in [1, 2]) or (FOskStatus in [1, 2]) or (FSaveList and (FSaveStatus = 2));
end;

function TPSPUtility.Handle(NID: Cardinal; out Value: Cardinal): Boolean;
begin
  Result := True;
  Value := 0;
  var A := FCPU.Registers[4];
  case NID of
    // Unopened utility dialogs have the NONE status. Their init calls remain
    // explicit unsupported operations until their actual services are present.
    $6332AA39, $946963F3, $BDA7D894, $D81957B7, $B57E95D9, $86ABDB1B:
      Value := 0;
    $F3F76017:
      Value := FOskStatus;
    $F6269B82:
      begin
        if (FOskStatus <> 0) or (FStatus <> 0) or (FSaveStatus <> 0) then
        begin
          Value := $80020190;
          Exit
        end;
        if not FMemory.IsValid(A, 64) then
        begin
          Value := $80110002;
          Exit
        end;
        if FMemory.Read32(A) <> 64 then
        begin
          Value := $80110004;
          Exit
        end;
        var Count := FMemory.Read32(A + 48);
        var Fields := FMemory.Read32(A + 52);
        if (Count = 0) or (Count > 16) or not FMemory.IsValid(Fields, Count * 52) then
        begin
          Value := $80110002;
          Exit
        end;
        for var I := 0 to Integer(Count) - 1 do
        begin
          var Field := Fields + Cardinal(I) * 52;
          var Capacity := FMemory.Read32(Field + 36);
          if (Capacity = 0) or (Capacity > 4096) or not FMemory.IsValid(FMemory.Read32(Field + 40), Capacity * 2) then
          begin
            Value := $80110002;
            Exit
          end;
        end;
        FOskAddress := A;
        FOskField := 0;
        FOskStatus := 1;
        FMemory.Write32(A + 56, 1);
        LoadOskField;
      end;
    $4B85C861:
      if FOskStatus <> 2 then
        Value := $80110001;
    $3DFAEBA9:
      if FOskStatus <> 3 then
        Value := $80110001
      else
      begin
        FOskStatus := 4;
        FMemory.Write32(FOskAddress + 56, 5)
      end;
    $50C4CD57:
      begin
        if (FSaveStatus <> 0) or (FStatus <> 0) or (FOskStatus <> 0) then
        begin
          Value := $80020190;
          Exit;
        end;
        if not FMemory.IsValid(A, 1480) then
        begin
          Value := $80110002;
          Exit;
        end;
        var Size := FMemory.Read32(A);
        if (Size <> 1480) and (Size <> 1500) and (Size <> 1536) then
        begin
          Value := $80110004;
          Exit;
        end;
        if not FMemory.IsValid(A, Size) then
        begin
          Value := $80110002;
          Exit;
        end;
        FSaveAddress := A;
        FSaveList := False;
        FSaveSelected := False;
        FSaveChoices := nil;
        FSaveStatus := 1;
      end;
    $8874DBE0:
      Value := FSaveStatus;
    $D4B95FFB:
      if FSaveStatus <> 2 then
        Value := $80110001
      else
        Savedata;
    $9790B33C:
      if FSaveStatus <> 3 then
        Value := $80110001
      else
        FSaveStatus := 4;
    $2AD8E239:
      begin
        if (FStatus <> 0) or (FOskStatus <> 0) or (FSaveStatus <> 0) then
        begin
          Value := $80020190;
          Exit;
        end;
        if not FMemory.IsValid(A, 572) then
        begin
          Value := $80110002;
          Exit;
        end;
        var Size := FMemory.Read32(A);
        if (Size <> 572) and (Size <> 580) and (Size <> 708) then
        begin
          Value := $80110004;
          Exit;
        end;
        if not FMemory.IsValid(A, Size) then
        begin
          Value := $80110002;
          Exit;
        end;
        FAddress := A;
        FOptions := 0;
        if Size >= 580 then
          FOptions := FMemory.Read32(A + 572);
        if FMemory.Read32(A + 52) = 0 then
          FText := Format('Error %.8x', [FMemory.Read32(A + 56)])
        else
          FText := FMemory.ReadString(A + 60, 512);
        FSelection := 1;
        if FOptions and $100 <> 0 then
          FSelection := 2;
        FStatus := 1;
      end;
    $9A1C91D7:
      Value := FStatus;
    $95FC253B:
      if FStatus <> 2 then
        Value := $80110001;
    $67AF3428:
      if FStatus <> 3 then
        Value := $80110001
      else
        FStatus := 4;
    $4928BD96:
      if not Visible then
        Value := $80110001
      else
      begin
        FMemory.Write32(FAddress + 28, 0);
        FMemory.Write32(FAddress + 48, 0);
        FStatus := 3;
      end;
  else
    Result := False;
  end;
end;

procedure TPSPUtility.Update(const Input: TEmulatorInput);
const
  Keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .';
begin
  if FOskStatus = 1 then
  begin
    FOskStatus := 2;
    FMemory.Write32(FOskAddress + 56, 3)
  end
  else if FOskStatus = 4 then
  begin
    FOskStatus := 0;
    FMemory.Write32(FOskAddress + 56, 0)
  end
  else if FOskStatus = 2 then
  begin
    var Pressed := Input.Buttons - FPrevious;
    if TEmulatorButton.Left in Pressed then
      FOskSelection := (FOskSelection + 63) mod 64;
    if TEmulatorButton.Right in Pressed then
      FOskSelection := (FOskSelection + 1) mod 64;
    if TEmulatorButton.Up in Pressed then
      FOskSelection := (FOskSelection + 56) mod 64;
    if TEmulatorButton.Down in Pressed then
      FOskSelection := (FOskSelection + 8) mod 64;
    var Field := OskFieldAddress;
    var Limit := FMemory.Read32(Field + 36) - 1;
    if FMemory.Read32(Field + 48) <> 0 then
      Limit := Min(Limit, FMemory.Read32(Field + 48));
    var Confirm := TEmulatorButton.A;
    var Backspace := TEmulatorButton.B;
    if FMemory.Read32(FOskAddress + 8) = 0 then
    begin
      Confirm := TEmulatorButton.B;
      Backspace := TEmulatorButton.A
    end;
    if (Confirm in Pressed) and (Cardinal(Length(FOskText)) < Limit) then
      FOskText := FOskText + Keys[FOskSelection + 1];
    if (Backspace in Pressed) and (FOskText <> '') then
      Delete(FOskText, Length(FOskText), 1);
    if TEmulatorButton.Select in Pressed then
      FinishOskField(True)
    else if TEmulatorButton.Start in Pressed then
      FinishOskField(False);
  end;
  if FSaveStatus = 1 then
    FSaveStatus := 2
  else if FSaveStatus = 4 then
    FSaveStatus := 0;
  if FSaveList and (FSaveStatus = 2) then
  begin
    var Pressed := Input.Buttons - FPrevious;
    if TEmulatorButton.Up in Pressed then
      FSaveChoice := (FSaveChoice + Length(FSaveChoices) - 1) mod Length(FSaveChoices);
    if TEmulatorButton.Down in Pressed then
      FSaveChoice := (FSaveChoice + 1) mod Length(FSaveChoices);
    var Confirm := TEmulatorButton.A;
    var Cancel := TEmulatorButton.B;
    if FMemory.Read32(FSaveAddress + 8) = 0 then
    begin
      Confirm := TEmulatorButton.B;
      Cancel := TEmulatorButton.A
    end;
    if Cancel in Pressed then
    begin
      FMemory.Write32(FSaveAddress + 28, 1);
      FSaveStatus := 3;
      FSaveList := False
    end
    else if Confirm in Pressed then
    begin
      FMemory.Zero(FSaveAddress + 76, 20);
      FMemory.Load(FSaveAddress + 76, Copy(TEncoding.UTF8.GetBytes(FSaveChoices[FSaveChoice]), 0, 19));
      FSaveSelected := True;
      FSaveList := False;
    end;
  end;

  if FStatus = 1 then
    FStatus := 2
  else if FStatus = 4 then
    FStatus := 0
  else if FStatus = 2 then
  begin
    var Pressed := Input.Buttons - FPrevious;
    if (FOptions and $10 <> 0) and ((TEmulatorButton.Left in Pressed) or (TEmulatorButton.Right in Pressed)) then
      FSelection := 3 - FSelection;
    var Confirm := TEmulatorButton.A;
    var Cancel := TEmulatorButton.B;
    if FMemory.Read32(FAddress + 8) = 0 then
    begin
      Confirm := TEmulatorButton.B;
      Cancel := TEmulatorButton.A;
    end;
    var Button: Cardinal := 0;
    if Confirm in Pressed then
      Button := FSelection;
    if (Cancel in Pressed) and (FOptions and $80 = 0) then
      Button := 3;
    if Button <> 0 then
    begin
      FMemory.Write32(FAddress + 28, 0);
      FMemory.Write32(FAddress + 48, 0);
      if FMemory.Read32(FAddress) >= 580 then
        FMemory.Write32(FAddress + 576, Button);
      FStatus := 3;
    end;
  end;
  FPrevious := Input.Buttons;
end;

// Original compact 5x7 capitals; lowercase is rendered using its capital glyph.
function Glyph(C: Char): string;
begin
  case UpCase(C) of
    'A':
      Result := '01110100011000111111100011000110001';
    'B':
      Result := '11110100011000111110100011000111110';
    'C':
      Result := '01111100001000010000100001000001111';
    'D':
      Result := '11110100011000110001100011000111110';
    'E':
      Result := '11111100001000011110100001000011111';
    'F':
      Result := '11111100001000011110100001000010000';
    'G':
      Result := '01111100001000010111100011000101111';
    'H':
      Result := '10001100011000111111100011000110001';
    'I':
      Result := '11111001000010000100001000010011111';
    'J':
      Result := '00111000100001000010100101001001100';
    'K':
      Result := '10001100101010011000101001001010001';
    'L':
      Result := '10000100001000010000100001000011111';
    'M':
      Result := '10001110111010110101100011000110001';
    'N':
      Result := '10001110011010110011100011000110001';
    'O':
      Result := '01110100011000110001100011000101110';
    'P':
      Result := '11110100011000111110100001000010000';
    'Q':
      Result := '01110100011000110001101011001001101';
    'R':
      Result := '11110100011000111110101001001010001';
    'S':
      Result := '01111100001000001110000010000111110';
    'T':
      Result := '11111001000010000100001000010000100';
    'U':
      Result := '10001100011000110001100011000101110';
    'V':
      Result := '10001100011000110001100010101000100';
    'W':
      Result := '10001100011000110101101011101110001';
    'X':
      Result := '10001100010101000100010101000110001';
    'Y':
      Result := '10001100010101000100001000010000100';
    'Z':
      Result := '11111000010001000100010001000011111';
    '0':
      Result := '01110100011001110101110011000101110';
    '1':
      Result := '00100011000010000100001000010001110';
    '2':
      Result := '01110100010000100010001000100011111';
    '3':
      Result := '11110000010000101110000010000111110';
    '4':
      Result := '00010001100101010010111110001000010';
    '5':
      Result := '11111100001000011110000010000111110';
    '6':
      Result := '01110100001000011110100011000101110';
    '7':
      Result := '11111000010001000100010000100001000';
    '8':
      Result := '01110100011000101110100011000101110';
    '9':
      Result := '01110100011000101111000010000101110';
    '.':
      Result := '00000000000000000000000000010000100';
    ',':
      Result := '00000000000000000000001000010001000';
    ':':
      Result := '00000001000010000000001000010000000';
    '-':
      Result := '00000000000000011111000000000000000';
    '/':
      Result := '00001000100001000100010000100010000';
    '?':
      Result := '01110100010000100010001000000000100';
    '(':
      Result := '00010001000100001000010000010000010';
    ')':
      Result := '01000001000001000010000100010001000';
  else
    Result := '';
  end;
end;

procedure TPSPUtility.Render(var Frame: TEmulatorFrame);

  procedure Text(X, Y: Integer; const Value: string);
  begin
    for var C in Value do
    begin
      var Bits := Glyph(C);
      for var I := 1 to Length(Bits) do
        if Bits[I] = '1' then
        begin
          var PX := X + (I - 1) mod 5;
          var PY := Y + (I - 1) div 5;
          if (PX >= 0) and (PX < Frame.Width) and (PY >= 0) and (PY < Frame.Height) then
            Frame.Pixels[PY * Frame.Width + PX] := $FFFFFFFF;
        end;
      Inc(X, 6);
    end;
  end;

begin
  if not Visible then
    Exit;
  for var Y := 24 to Frame.Height - 25 do
    for var X := 12 to Frame.Width - 13 do
      Frame.Pixels[Y * Frame.Width + X] := $FF263448;
  if FSaveList and (FSaveStatus = 2) then
  begin
    if FMemory.Read32(FSaveAddress + 48) = 4 then
      Text(26, 36, 'LOAD SAVED GAME')
    else
      Text(26, 36, 'SAVE GAME');
    var First := Max(0, FSaveChoice - 5);
    for var I := First to Min(High(FSaveChoices), First + 9) do
    begin
      var Name := FSaveChoices[I];
      if Name = '' then
        Name := 'DEFAULT';
      if I = FSaveChoice then
        Name := '[ ' + Name + ' ]';
      Text(26, 60 + (I - First) * 14, Name);
    end;
    Text(26, Frame.Height - 42, 'UP / DOWN SELECT - CONFIRM / CANCEL');
    Exit;
  end;
  if FOskStatus in [1, 2] then
  begin
    Text(26, 36, 'PSP KEYBOARD');
    Text(26, 55, Copy(FOskText, 1, 70));
    const Keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .';
    for var I := 0 to 63 do
    begin
      var LabelText := string(Keys[I + 1]);
      if Cardinal(I) = FOskSelection then
        LabelText := '[' + LabelText + ']';
      Text(32 + (I mod 8) * 36, 80 + (I div 8) * 16, LabelText);
    end;
    Text(26, Frame.Height - 42, 'CROSS ADD / CIRCLE DELETE / START DONE / SELECT CANCEL');
    Exit;
  end;
  Text(26, 36, 'PSP');
  var Words := FText.Split([' ', #10, #13]);
  var Line := '';
  var Y := 60;
  for var Word in Words do
  begin
    if Length(Line) + Length(Word) > 70 then
    begin
      Text(26, Y, Line);
      Inc(Y, 12);
      Line := '';
    end;
    if Line <> '' then
      Line := Line + ' ';
    Line := Line + Word;
  end;
  Text(26, Y, Line);
  if FOptions and $10 <> 0 then
    if FSelection = 1 then
      Text(26, Frame.Height - 48, '[ YES ]    NO')
    else
      Text(26, Frame.Height - 48, 'YES    [ NO ]')
  else
    Text(26, Frame.Height - 48, 'CONFIRM / CANCEL');
end;

end.

