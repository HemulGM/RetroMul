unit S32.RomSets;

interface

uses
  System.SysUtils, Core.Archive.Container;

type
  TS32RomFile = record
    Region, Name: string;
    CRC: Cardinal;
    Offset, Size, Stride, SourceOffset, FileSize, Group: Integer;
  end;

  TS32Region = record
    Name: string;
    Size: Integer;
  end;

  TS32RomSet = record
    Name, Parent, Title, Inputs, Unsupported: string;
    Rotation: Integer;
    Regions: TArray<TS32Region>;
    Files: TArray<TS32RomFile>;
    class function Find(const Name: string; out RomSet: TS32RomSet): Boolean; static;
    class function Identify(const Archive: IArchiveContainer; const Hint: string; out RomSet: TS32RomSet): Boolean; static;
  end;

implementation

{$I S32.RomData.inc}

function Parse(const Data: string): TS32RomSet;
begin
  Result := Default(TS32RomSet);
  var P := Data.Split(['|']);
  Result.Name := P[0];
  Result.Parent := P[1];
  Result.Rotation := StrToInt(P[2]);
  Result.Title := P[3];
  Result.Inputs := P[4];
  Result.Unsupported := P[5];
  var R := P[6].Split([';']);
  SetLength(Result.Regions, Length(R));
  for var i := 0 to High(R) do
  begin
    var V := R[i].Split([',']);
    Result.Regions[i].Name := V[0];
    Result.Regions[i].Size := StrToInt(V[1]);
  end;
  R := P[7].Split([';']);
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
    Result.Files[i].Group := StrToInt(V[8]);
  end;
end;

class function TS32RomSet.Find(const Name: string; out RomSet: TS32RomSet): Boolean;
begin
  for var Data in SYSTEM32_SET_DATA do
    if SameText(Data.Substring(0, Data.IndexOf('|')), Name) then
    begin
      RomSet := Parse(Data);
      Exit(True);
    end;
  RomSet := Default(TS32RomSet);
  Result := False;
end;

class function TS32RomSet.Identify(const Archive: IArchiveContainer; const Hint: string; out RomSet: TS32RomSet): Boolean;
begin
  Result := False;
  RomSet := Default(TS32RomSet);
  if Archive = nil then
    Exit;
  var Name := ChangeFileExt(ExtractFileName(Hint.Replace('/', PathDelim)), '');
  var Best: Int64 := -1;
  for var Data in SYSTEM32_SET_DATA do
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

