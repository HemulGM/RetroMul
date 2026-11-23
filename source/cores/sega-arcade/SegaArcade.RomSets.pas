unit SegaArcade.RomSets;

interface

uses
  System.SysUtils, Core.Archive.Container;

type
  TSegaArcadeMCUSimulation = (smNone, smToughTurf, smWonderBoy3);

  TSegaArcadeRomFile = record
    Region, Name: string;
    CRC: Cardinal;
    Offset, Size, Stride, SourceOffset, FileSize: Integer;
  end;

  TSegaArcadeRegion = record
    Name: string;
    Size: Integer;
  end;

  // Board IDs and input profiles are local to each platform catalog.
  TSegaArcadeRomSet = record
    Name, Parent, Title, Inputs, Unsupported: string;
    Board, Rotation, Crypto: Integer;
    MCU: Boolean; // Physical board has an 8751.
    MCUSimulation: TSegaArcadeMCUSimulation;
    DIPs: array[0..1] of Byte;
    Regions: TArray<TSegaArcadeRegion>;
    Files: TArray<TSegaArcadeRomFile>;
    class function Parse(const Data: string): TSegaArcadeRomSet; static;
    class function FindIn(const Catalog: array of string; const Name: string; out RomSet: TSegaArcadeRomSet): Boolean; static;
    class function IdentifyIn(const Catalog: array of string; const Archive: IArchiveContainer; const Hint: string; out RomSet: TSegaArcadeRomSet): Boolean; static;
  end;

implementation

class function TSegaArcadeRomSet.Parse(const Data: string): TSegaArcadeRomSet;
begin
  Result := Default(TSegaArcadeRomSet);
  var P := Data.Split(['|']);
  Result.Name := P[0];
  Result.Parent := P[1];
  Result.Board := StrToInt(P[2]);
  Result.Rotation := StrToInt(P[3]);
  Result.Title := P[4];
  Result.Inputs := P[5];
  Result.Unsupported := P[6];
  var Hardware := P[7].Split([',']);
  Result.Crypto := StrToInt(Hardware[0]);
  Result.MCU := Hardware[3] = '1';
  Result.MCUSimulation := TSegaArcadeMCUSimulation(StrToInt(Hardware[4]));
  Result.DIPs[0] := Byte(StrToInt(Hardware[1]));
  Result.DIPs[1] := Byte(StrToInt(Hardware[2]));
  var R := P[8].Split([';']);
  SetLength(Result.Regions, Length(R));
  for var i := 0 to High(R) do
  begin
    var V := R[i].Split([',']);
    Result.Regions[i].Name := V[0];
    Result.Regions[i].Size := StrToInt(V[1]);
  end;
  R := P[9].Split([';']);
  SetLength(Result.Files, Length(R));
  for var i := 0 to High(R) do
  begin
    var V := R[i].Split([',']);
    Result.Files[i].Region := V[0];
    Result.Files[i].Name := V[1];
    Result.Files[i].CRC := StrToUInt(V[2]);
    Result.Files[i].Offset := StrToInt(V[3]);
    Result.Files[i].Size := StrToInt(V[4]);
    Result.Files[i].Stride := StrToInt(V[5]);
    Result.Files[i].SourceOffset := StrToInt(V[6]);
    Result.Files[i].FileSize := StrToInt(V[7]);
  end;
end;

class function TSegaArcadeRomSet.FindIn(const Catalog: array of string; const Name: string; out RomSet: TSegaArcadeRomSet): Boolean;
begin
  for var Data in Catalog do
    if SameText(Data.Substring(0, Data.IndexOf('|')), Name) then
    begin
      RomSet := Parse(Data);
      Exit(True);
    end;
  RomSet := Default(TSegaArcadeRomSet);
  Result := False;
end;

class function TSegaArcadeRomSet.IdentifyIn(const Catalog: array of string; const Archive: IArchiveContainer; const Hint: string; out RomSet: TSegaArcadeRomSet): Boolean;
begin
  Result := False;
  RomSet := Default(TSegaArcadeRomSet);
  if Archive = nil then
    Exit;
  var Name := ChangeFileExt(ExtractFileName(Hint.Replace('/', PathDelim)), '');
  var Best: Int64 := -1;
  for var Data in Catalog do
  begin
    var Candidate := Parse(Data);
    var Complete := True;
    var Count := 0;
    for var F in Candidate.Files do
      if F.Region = 'maincpu' then
      begin
        Inc(Count);
        if Archive.FindCRC(F.CRC) < 0 then
          Complete := False;
      end;
    if Complete and (Count > 0) then
    begin
      var Score: Int64 := 0;
      for var F in Candidate.Files do
        if Archive.FindCRC(F.CRC) >= 0 then
          Inc(Score, F.Size);
      if SameText(Candidate.Name, Name) then
        Inc(Score, Int64(1) shl 48);
      if Score > Best then
      begin
        Best := Score;
        RomSet := Candidate;
      end;
    end;
  end;
  if Best >= 0 then
    Exit(True);
  // A named split or incomplete set gets a precise missing-ROM diagnostic.
  Result := FindIn(Catalog, Name, RomSet);
end;

end.

