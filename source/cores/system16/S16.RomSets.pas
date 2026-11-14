unit S16.RomSets;

interface

uses
  System.SysUtils, Core.Archive.Container;

type
  TS16MCUSimulation = (smNone, smToughTurf, smWonderBoy3);

  TS16RomFile = record
    Region, Name: string;
    CRC: Cardinal;
    Offset, Size, Stride, SourceOffset, FileSize: Integer;
  end;

  TS16Region = record
    Name: string;
    Size: Integer;
  end;

  // 0=16A, 1=5358 small, 2=5358, 3=5521, 4=5704, 5=5797.
  TS16RomSet = record
    Name, Parent, Title, Inputs, Unsupported: string;
    Board, Rotation, Crypto: Integer;
    MCU: Boolean; // Physical board has an 8751.
    MCUSimulation: TS16MCUSimulation;
    DIPs: array[0..1] of Byte;
    Regions: TArray<TS16Region>;
    Files: TArray<TS16RomFile>;
    class function Find(const Name: string; out RomSet: TS16RomSet): Boolean; static;
    class function Identify(const Archive: IArchiveContainer; const Hint: string; out RomSet: TS16RomSet): Boolean; static;
  end;

implementation

{$I S16.RomData.inc}

function Parse(const Data: string): TS16RomSet;
begin
  Result := Default(TS16RomSet);
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
  Result.MCUSimulation := TS16MCUSimulation(StrToInt(Hardware[4]));
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

class function TS16RomSet.Find(const Name: string; out RomSet: TS16RomSet): Boolean;
begin
  for var Data in SYSTEM16_SET_DATA do
    if SameText(Data.Substring(0, Data.IndexOf('|')), Name) then
    begin
      RomSet := Parse(Data);
      Exit(True);
    end;
  RomSet := Default(TS16RomSet);
  Result := False;
end;

class function TS16RomSet.Identify(const Archive: IArchiveContainer; const Hint: string; out RomSet: TS16RomSet): Boolean;
begin
  Result := False;
  RomSet := Default(TS16RomSet);
  if Archive = nil then
    Exit;
  var Name := ChangeFileExt(ExtractFileName(Hint.Replace('/', PathDelim)), '');
  var Best: Int64 := -1;
  for var Data in SYSTEM16_SET_DATA do
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
  Result := Find(Name, RomSet);
end;

end.

