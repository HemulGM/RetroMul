unit RetroTune.VortexText;

interface

uses
  System.SysUtils;

function CompileVortexText(const Data: TBytes): TBytes;

implementation

uses
  System.Classes, System.Generics.Collections, System.Math;

function CompileVortexText(const Data: TBytes): TBytes;
var
  Sections: TObjectDictionary<string, TStringList>;
  Lines, Section: TStringList;
  Bytes: TList<Byte>;
  Header: TStringList;
  Order: TArray<string>;
  Map: TDictionary<Integer, Integer>;
  Names: TList<Integer>;
  PatternBase, Loop, Version, Index, B0, B1, Tone, Noise, Cmd, Delay, Param: Integer;

  procedure Need(Condition: Boolean; const Message: string);
  begin
    if not Condition then
      raise EArgumentException.Create('Vortex TXT: ' + Message);
  end;

  function Hex(const S: string): Integer;
  begin
    Need(TryStrToInt('$' + S.Replace('.', '0'), Result), 'invalid hexadecimal value');
  end;

  function Digit(C: Char): Integer;
  begin
    if C = '.' then
      Exit(0);
    C := UpCase(C);
    if CharInSet(C, ['0'..'9']) then
      Result := Ord(C) - Ord('0')
    else
    begin
      Need(CharInSet(C, ['A'..'V']), 'invalid instrument digit');
      Result := Ord(C) - Ord('A') + 10;
    end;
  end;

  procedure Put(V: Integer);
  begin
    Need(Bytes.Count < 65535, 'module exceeds 64 KiB');
    Bytes.Add(V and 255);
  end;

  procedure WordValue(V: Integer);
  begin
    Put(V);
    Put((V and 65535) shr 8);
  end;

  procedure SetWord(P, V: Integer);
  begin
    Need((V >= 0) and (V < 65536), 'invalid offset');
    Bytes[P] := V and 255;
    Bytes[P + 1] := V shr 8;
  end;

  function GetSection(const Name: string): TStringList;
  begin
    if not Sections.TryGetValue(Name, Result) then
      Result := nil;
  end;

  function SignedHex(const S: string; Width: Integer): Integer;
  begin
    Need((Length(S) = Width + 2) and CharInSet(S[1], ['+', '-']) and
      CharInSet(S[Length(S)], ['_', '^']), 'invalid instrument offset');
    Result := Hex(Copy(S, 2, Width));
    if S[1] = '-' then
      Result := -Result;
  end;

  procedure Text(P, Count: Integer; const S: string);
  begin
    var Enc := TEncoding.UTF8.GetBytes(S);
    for var I := 0 to Min(Count, Length(Enc)) - 1 do
      Bytes[P + I] := Enc[I];
  end;

  procedure Row(const S: string; Channel: Integer);
  const
    Semitones: array[0..6] of Integer = (9, 11, 0, 2, 4, 5, 7);
  begin
    var Fields := S.Split(['|']);
    Need(Length(Fields) = 5, 'invalid pattern row');
    var Cell := Fields[Channel + 2].Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    Need((Length(Cell) = 3) and (Length(Cell[0]) = 3) and (Length(Cell[1]) = 4) and (Length(Cell[2]) = 4), 'invalid channel row');
    Cmd := Hex(Cell[2][1]);
    Delay := Hex(Cell[2][2]);
    Param := Hex(Copy(Cell[2], 3, 2));
    if (Cmd <> 0) and not ((Cmd = 11) and (Param = 0)) then
      case Cmd of
        1, 2:
          Put(1);
        3:
          Put(2);
        4:
          Put(3);
        5:
          Put(4);
        6:
          Put(5);
        9, 10:
          Put(8);
        11:
          Put(9);
      else
        Need(False, 'unsupported pattern command');
      end;
    if (Channel = 1) and (Fields[1] <> '..') then
    begin
      var N := Hex(Fields[1]);
      Need(N < 32, 'noise period');
      Put($20 + N);
    end;
    var Samp := Digit(Cell[1][1]);
    var Env := Digit(Cell[1][2]);
    var Orn := Digit(Cell[1][3]);
    var Vol := Digit(Cell[1][4]);
    Need((Samp < 32) and (Orn < 16) and (Env < 16) and (Vol < 16), 'channel fields');
    if Samp <> 0 then
      Put($D0 + Samp);
    if Env = 15 then
    begin
      Put($B0);
      if Orn = 0 then
        Put($40);
    end
    else if Env <> 0 then
    begin
      Put($B1 + Env);
      var E := Hex(Fields[0]);
      Put(E shr 8);
      Put(E);
    end;
    if Orn <> 0 then
      Put($40 + Orn);
    if Vol <> 0 then
      Put($C0 + Vol);
    Put($B1);
    Put(1);
    if Cell[0] = '---' then
      Put($D0)
    else if Cell[0] = 'R--' then
      Put($C0)
    else
    begin
      Need(CharInSet(Cell[0][1], ['A'..'G']) and CharInSet(Cell[0][2], ['-', '#']) and
        CharInSet(Cell[0][3], ['1'..'8']), 'invalid note');
      var Note := (Ord(Cell[0][3]) - Ord('1')) * 12 + Semitones[Ord(Cell[0][1]) - Ord('A')] + Ord(Cell[0][2] = '#');
      Need(Note < 96, 'note exceeds eight octaves');
      Put($50 + Note);
    end;
    case Cmd of
      1, 2, 9, 10:
        begin
          Put(Delay);
          if Cmd in [2, 10] then
            WordValue(-Param)
          else
            WordValue(Param);
        end;
      3:
        begin
          Put(Delay);
          WordValue(0);
          WordValue(Param);
        end;
      4, 5:
        Put(Param);
      6:
        begin
          Put(Param shr 4);
          Put(Param and 15);
        end;
      11:
        if Param <> 0 then
          Put(Param);
    end;
  end;

begin
  Sections := TObjectDictionary<string, TStringList>.Create([doOwnsValues]);
  Lines := TStringList.Create;
  Bytes := TList<Byte>.Create;
  Map := TDictionary<Integer, Integer>.Create;
  Names := TList<Integer>.Create;
  try
    Lines.Text := TEncoding.UTF8.GetString(Data).TrimLeft([Char($FEFF)]);
    Section := nil;
    for var RawLine in Lines do
    begin
      var S := RawLine.Trim;
      if S = '' then
        Continue;
      if S.StartsWith('[') and S.EndsWith(']') then
      begin
        var Name := Copy(S, 2, Length(S) - 2);
        Need(not Sections.ContainsKey(Name), 'duplicate section');
        Section := TStringList.Create;
        Sections.Add(Name, Section);
      end
      else
      begin
        Need(Section <> nil, 'missing section header');
        Section.Add(S);
      end;
    end;
    Header := GetSection('Module');
    Need(Header <> nil, 'missing [Module]');
    Need(Header.Values['Version'].StartsWith('3.'), 'unsupported version');
    Version := StrToInt(Copy(Header.Values['Version'], 3, 1));
    Order := Header.Values['PlayOrder'].Split([',']);
    Need((Length(Order) > 0) and (Length(Order) < 256), 'invalid play order');
    Loop := 0;
    for var I := 0 to High(Order) do
    begin
      var S := Order[I].Trim;
      if S.StartsWith('L') then
      begin
        Loop := I;
        S := S.Substring(1);
      end;
      var N := StrToInt(S);
      Need((N >= 0) and (N <= 255), 'pattern index');
      Order[I] := S;
      if not Map.ContainsKey(N) then
      begin
        Map.Add(N, Names.Count);
        Names.Add(N);
      end;
    end;
    Need(Names.Count <= 85, 'more than 85 distinct patterns');
    PatternBase := 202 + Length(Order);
    for var I := 0 to PatternBase + Names.Count * 6 - 1 do
      Put(0);
    for var I := 0 to 98 do
      Bytes[I] := 32;
    Text(0, 30, Format('ProTracker 3.%d compilation of ', [Version]));
    Text(30, 32, Header.Values['Title']);
    Text(66, 32, Header.Values['Author']);
    Bytes[98] := 32;
    Index := StrToInt(Header.Values['NoteTable']);
    Need(Index in [0..3], 'note table');
    Bytes[99] := Index;
    Index := StrToInt(Header.Values['Speed']);
    Need((Index > 0) and (Index < 256), 'speed');
    Bytes[100] := Index;
    Bytes[101] := Length(Order);
    Bytes[102] := Loop;
    SetWord(103, PatternBase);
    for var I := 0 to High(Order) do
      Bytes[201 + I] := Map[StrToInt(Order[I])] * 3;
    Bytes[201 + Length(Order)] := 255;
    for var P := 0 to Names.Count - 1 do
    begin
      Section := GetSection('Pattern' + IntToStr(Names[P]));
      Need((Section <> nil) and (Section.Count > 0) and (Section.Count <= 256), 'missing or oversized pattern');
      for var C := 0 to 2 do
      begin
        SetWord(PatternBase + P * 6 + C * 2, Bytes.Count);
        for var S in Section do
          Row(S, C);
        Put(0);
      end;
    end;
    for var I := 0 to 31 do
    begin
      SetWord(105 + I * 2, Bytes.Count);
      Section := GetSection('Sample' + IntToStr(I));
      if Section = nil then
      begin
        Put(0);
        Put(1);
        Put(1);
        Put($90);
        WordValue(0);
        Continue;
      end;
      Need((Section.Count > 0) and (Section.Count <= 64), 'sample length');
      Loop := -1;
      for var J := 0 to Section.Count - 1 do
        if Section[J].EndsWith(' L') then
        begin
          Need(Loop = -1, 'duplicate sample loop');
          Loop := J;
        end;
      Need(Loop >= 0, 'missing sample loop');
      Put(Loop);
      Put(Section.Count);
      for var S in Section do
      begin
        var F := S.Split([' '], TStringSplitOptions.ExcludeEmpty);
        Need((Length(F) in [4, 5]) and (Length(F[0]) = 3) and (Length(F[3]) = 2), 'sample row');
        Need(CharInSet(F[0][1], ['t', 'T']) and CharInSet(F[0][2], ['n', 'N']) and CharInSet(F[0][3], ['e', 'E']), 'sample masks');
        Tone := SignedHex(F[1], 3);
        Noise := SignedHex(F[2], 2);
        B0 := Ord(F[0][3] = 'e') or ((Noise and 31) shl 1);
        B1 := Hex(F[3][1]) or (Ord(F[0][1] = 't') shl 4) or (Ord(F[0][2] = 'n') shl 7);
        if F[1][5] = '^' then
          B1 := B1 or $40;
        if F[2][4] = '^' then
          B1 := B1 or $20;
        Need(CharInSet(F[3][2], ['_', '+', '-']), 'amplitude slide');
        if F[3][2] = '+' then
          B0 := B0 or $C0
        else if F[3][2] = '-' then
          B0 := B0 or $80;
        Put(B0);
        Put(B1);
        WordValue(Tone);
      end;
    end;
    for var I := 0 to 15 do
    begin
      SetWord(169 + I * 2, Bytes.Count);
      Section := GetSection('Ornament' + IntToStr(I));
      if Section = nil then
      begin
        Put(0);
        Put(1);
        Put(0);
        Continue;
      end;
      Need(Section.Count = 1, 'ornament row count');
      var Items := Section[0].Split([',']);
      Need((Length(Items) > 0) and (Length(Items) < 256), 'ornament length');
      Loop := 0;
      for var J := 0 to High(Items) do
        if Items[J].StartsWith('L') then
        begin
          Loop := J;
          Items[J] := Items[J].Substring(1);
        end;
      Put(Loop);
      Put(Length(Items));
      for var S in Items do
      begin
        var N := StrToInt(S);
        Need((N >= -128) and (N <= 127), 'ornament offset');
        Put(N);
      end;
    end;
    Result := Bytes.ToArray;
  finally
    Names.Free;
    Map.Free;
    Bytes.Free;
    Lines.Free;
    Sections.Free;
  end;
end;

end.

