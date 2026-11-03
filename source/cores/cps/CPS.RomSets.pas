unit CPS.RomSets;

interface

uses
  System.SysUtils, System.Classes, Core.Archive.Container;

type
  TCPSGeneration = (CPS1 = 1, CPS2 = 2, CPS3 = 3);

  TCPSRomFile = record
    Region, Name: string;
    CRC: Cardinal;
    Offset, Size, SourceOffset, Group, Stride, FillValue: Integer;
    Swap: Boolean;
  end;

  TCPSRegion = record
    Name: string;
    Size: Integer;
  end;

  PCPSRomFile = ^TCPSRomFile;

  TCPSGfxRange = record
    Mask, First, Last, Bank: Integer;
  end;

  TCPSBoard = record
    IDRegister, IDValue: Integer;
    Multiply1, Multiply2, ProductLow, ProductHigh: Integer;
    LayerControl, PaletteControl: Integer;
    Priority: array[0..3] of Integer;
    LayerEnable: array[0..4] of Integer;
    BankSize: array[0..3] of Integer;
    Input2, Input3, Output2, VideoFlags: Integer;
    Ranges: TArray<TCPSGfxRange>;
  end;

  TCPSRomSet = record
    Name: string;
    Generation: TCPSGeneration;
    Regions: TArray<TCPSRegion>;
    Files: TArray<TCPSRomFile>;
    Board: TCPSBoard;
    MasterKey: array[0..1] of Cardinal;
    EncryptedBytes: Cardinal;
    DiscName: string;
    Parent: string;
    Machine, Inputs, Init: string;
    Rotation, Clock: Integer;
    DIPs: array[0..2] of Byte;
    class function Find(const Name: string; out RomSet: TCPSRomSet): Boolean; static;
    // Central-directory metadata only. Loading verifies the actual content.
    class function Identify(Archive: IArchiveContainer; const Hint: string; out RomSet: TCPSRomSet): Boolean; static;
    class function IdentifyStream(Stream: TStream; const Hint: string; out RomSet: TCPSRomSet): Boolean; static;
  end;

  PCPSBoard = ^TCPSBoard;

implementation

uses
  Core.MediaArchive;

{$I CPS.RomData.inc}

function Int(const S: string): Integer;
begin
  Result := StrToInt(S);
end;

function Parse(const Data: string): TCPSRomSet;
begin
  Result := Default(TCPSRomSet);
  var Parts := Data.Split(['|']);
  Result.Name := Parts[0];
  Result.Generation := TCPSGeneration(Int(Parts[1]));
  FillChar(Result.DIPs, SizeOf(Result.DIPs), $FF);
  if (Length(Parts) > 11) and (Parts[11] <> '') then
  begin
    var DIPs := Parts[11].Split([',']);
    for var i := 0 to 2 do
      Result.DIPs[i] := Byte(Int(DIPs[i]));
  end;
  if Length(Parts) > 8 then
    Result.DiscName := Parts[8];
  if Length(Parts) > 9 then
    Result.Parent := Parts[9];
  if Length(Parts) > 10 then
  begin
    var Hardware := Parts[10].Split([',']);
    Result.Machine := Hardware[0];
    Result.Inputs := Hardware[1];
    Result.Init := Hardware[2];
    Result.Rotation := Int(Hardware[3]);
    Result.Clock := Int(Hardware[4]);
  end;
  if (Length(Parts) > 7) and (Parts[7] <> '') then
  begin
    var Key := Parts[7].Split([',']);
    Result.MasterKey[0] := StrToUInt(Key[0]);
    Result.MasterKey[1] := StrToUInt(Key[1]);
    Result.EncryptedBytes := StrToUInt(Key[2]);
  end;
  var Regions := Parts[2].Split([';']);
  SetLength(Result.Regions, Length(Regions));
  for var i := 0 to High(Regions) do
  begin
    var R := Regions[i].Split([',']);
    Result.Regions[i].Name := R[0];
    Result.Regions[i].Size := Int(R[1]);
  end;
  var B: PCPSBoard := @Result.Board;
  if (Length(Parts) > 12) and (Parts[12] <> '') then
  begin
    var IO := Parts[12].Split([',']);
    B.Input2 := Int(IO[0]);
    B.Input3 := Int(IO[1]);
    B.Output2 := Int(IO[2]);
    B.VideoFlags := Int(IO[3]);
  end;
  B.IDRegister := $32;
  B.IDValue := $FFFF;
  B.Multiply1 := 0;
  B.Multiply2 := 2;
  B.ProductLow := 4;
  B.ProductHigh := 6;
  B.LayerControl := $26;
  B.PaletteControl := $30;
  for var i := 0 to 3 do
    B.Priority[i] := $28 + i * 2;
  for var i := 0 to 2 do
    B.LayerEnable[i] := 2 shl i;
  if Parts[3] <> '' then
  begin
    var P := Parts[3].Split([',']);
    B.IDRegister := Int(P[0]);
    B.IDValue := Int(P[1]);
    B.Multiply1 := Int(P[2]);
    B.Multiply2 := Int(P[3]);
    B.ProductLow := Int(P[4]);
    B.ProductHigh := Int(P[5]);
    B.LayerControl := Int(P[9]);
    for var i := 0 to 3 do
      B.Priority[i] := Int(P[10 + i]);
    B.PaletteControl := Int(P[14]);
    for var i := 0 to 4 do
      B.LayerEnable[i] := Int(P[15 + i]);
    P := Parts[4].Split([',']);
    for var i := 0 to 3 do
      B.BankSize[i] := Int(P[i]);
    var Ranges := Parts[5].Split([';']);
    SetLength(B.Ranges, Length(Ranges));
    for var i := 0 to High(Ranges) do
    begin
      P := Ranges[i].Split([',']);
      B.Ranges[i].Mask := Int(P[0]);
      B.Ranges[i].First := Int(P[1]);
      B.Ranges[i].Last := Int(P[2]);
      B.Ranges[i].Bank := Int(P[3]);
    end;
  end;
  var Files := Parts[6].Split([';']);
  SetLength(Result.Files, Length(Files));
  for var i := 0 to High(Files) do
  begin
    var P := Files[i].Split([',']);
    var F: PCPSRomFile := @Result.Files[i];
    F.Region := P[0];
    F.Name := P[1];
    F.CRC := StrToUInt('$' + P[2]);
    F.Offset := Int(P[3]);
    F.Size := Int(P[4]);
    F.SourceOffset := Int(P[5]);
    F.Group := Int(P[6]);
    F.Stride := Int(P[7]);
    F.Swap := P[8] = '1';
    F.FillValue := -1;
    if F.Name = '#fill' then
      F.FillValue := F.SourceOffset;
  end;
end;

class function TCPSRomSet.Find(const Name: string; out RomSet: TCPSRomSet): Boolean;
begin
  for var Data in CPS_SET_DATA do
    if SameText(Data.Substring(0, Data.IndexOf('|')), Name) then
    begin
      RomSet := Parse(Data);
      Exit(True);
    end;

  RomSet := Default(TCPSRomSet);
  Result := False;
end;

class function TCPSRomSet.Identify(Archive: IArchiveContainer; const Hint: string; out RomSet: TCPSRomSet): Boolean;

  function HasProgram(const Candidate: TCPSRomSet): Boolean;
  begin
    Result := False;
    for var F in Candidate.Files do
      if not F.Name.StartsWith('#') and ((F.Region = 'maincpu') or (F.Region = 'bios') or (F.Region = 'patch') or
        F.Region.StartsWith('simm1.') or F.Region.StartsWith('simm2.')) then
      begin
        var Found := False;
        for var i := 0 to Archive.Count - 1 do
          if not Archive.Entries[i].IsDirectory and (Archive.Checksum(i) = F.CRC) then
          begin
            Found := True;
            Break;
          end;

        if not Found then
          Exit(False);

        Result := True;
      end;
  end;

begin
  // Prefer content over the archive label (some old collections name US BIOSes
  // after the parent). A named incomplete set still receives a useful error.
  var HintSet: TCPSRomSet;
  var HasHint := Find(ChangeFileExt(ExtractFileName(StringReplace(Hint, '/', PathDelim, [rfReplaceAll])), ''), HintSet);
  var BestScore: Int64 := -1;
  for var Data in CPS_SET_DATA do
  begin
    var Candidate := Parse(Data);
    if HasProgram(Candidate) then
    begin
      var Score: Int64 := 0;
      for var F in Candidate.Files do
        if not F.Name.StartsWith('#') then
          for var i := 0 to Archive.Count - 1 do
            if not Archive.Entries[i].IsDirectory and (Archive.Checksum(i) = F.CRC) then
            begin
              Inc(Score, F.Size);
              Break;
            end;

      if HasHint and SameText(Candidate.Name, HintSet.Name) then
        Inc(Score, Int64(1) shl 48);
      if Score > BestScore then
      begin
        BestScore := Score;
        RomSet := Candidate;
      end;
    end;
  end;
  if BestScore >= 0 then
    Exit(True);

  if HasHint then
  begin
    RomSet := HintSet;
    Exit(True);
  end;

  RomSet := Default(TCPSRomSet);
  Result := False;
end;

class function TCPSRomSet.IdentifyStream(Stream: TStream; const Hint: string; out RomSet: TCPSRomSet): Boolean;
begin
  Result := Identify(OpenMediaArchive(Stream, Hint), Hint, RomSet);
end;

end.

