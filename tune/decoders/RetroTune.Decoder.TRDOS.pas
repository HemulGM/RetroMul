unit RetroTune.Decoder.TRDOS;

interface

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, RetroTune.Decoder,
  RetroTune.Binary;

type
  TDiskSong = record
    Name, Extension: string;
    Data: TBytes;
    Info: TTuneInfo;
  end;

  TTRDOSDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FSongs: TArray<TDiskSong>;
    FBase: ITuneDecoder;
    FInfo: TTuneInfo;
  public
    constructor Create(const Data: TBytes; SCL: Boolean);
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function Signature(const Data: TBytes; At: Integer; const Text: AnsiString): Boolean;
begin
  Result := False;
  if (At < 0) or (At > Length(Data) - Length(Text)) then
    Exit;
  for var I := 1 to Length(Text) do
    if Data[At + I - 1] <> Ord(Text[I]) then
      Exit;
  Result := True;
end;

function FindMusic(const Data: TBytes; out Module: TBytes; out Extension: string; out Decoder: ITuneDecoder): Boolean;
var
  Candidates: TList<string>;

  procedure Add(const Ext: string);
  begin
    if not Candidates.Contains(Ext) then
      Candidates.Add(Ext);
  end;

  function PointerAt(P: Integer; Minimum: Integer = 0): Boolean;
  begin
    var V := LE16(Data, P);
    Result := (V >= Minimum) and (V < Length(Data));
  end;

begin
  Result := False;
  Module := nil;
  Extension := '';
  Decoder := nil;
  if (Length(Data) < 10) or (Length(Data) > 65536) then
    Exit;
  Candidates := TList<string>.Create;
  try
  // A compiled TR-DOS file can contain a PT3 module after its executable player.
    for var At := 0 to Length(Data) - 201 do
      if Signature(Data, At, 'ProTracker 3.') or Signature(Data, At, 'Vortex Tracker') then
      begin
        var D := Copy(Data, At, Length(Data) - At);
        try
          Decoder := TTuneDecoders.OpenData(D, '.pt3');
     // Compiled TurboSound players can contain two modules without a TS footer.
     // Keep native PT3 TurboSound intact; otherwise validate every second header.
          if (D[98] = $20) and not Signature(D, Length(D) - 4, '02TS') and not Signature(D, Length(D) - 4, '03TS') then
          begin
            for var Next := At + 202 to Length(Data) - 202 do
              if Signature(Data, Next, 'ProTracker 3.') or Signature(Data, Next, 'Vortex Tracker') then
              begin
                var Second := Copy(Data, Next, Length(Data) - Next);
                var CheckDecoder: ITuneDecoder;
                try
                  CheckDecoder := TTuneDecoders.OpenData(Second, '.pt3');
                  if Second[98] <> $20 then
                    Continue;
                  var FirstSize := Next - At;
                  var SecondSize := Length(Second);
                  var Both := Copy(Data, At, Length(Data) - At);
                  var Footer := Length(Both);
                  SetLength(Both, Footer + 16);
                  for var I := 0 to 2 do
                  begin
                    Both[Footer + I] := Ord('PT3'[I + 1]);
                    Both[Footer + 6 + I] := Ord('PT3'[I + 1]);
                  end;
                  Both[Footer + 3] := Ord('!');
                  Both[Footer + 9] := Ord('!');
                  Both[Footer + 4] := FirstSize and 255;
                  Both[Footer + 5] := (FirstSize shr 8) and 255;
                  Both[Footer + 10] := SecondSize and 255;
                  Both[Footer + 11] := (SecondSize shr 8) and 255;
                  for var I := 0 to 3 do
                    Both[Footer + 12 + I] := Ord('02TS'[I + 1]);
                  Decoder := TTuneDecoders.OpenData(Both, '.pt3');
                  D := Both;
                  Break;
                except
                  on E: EArgumentException do
                    CheckDecoder := nil;
                end;
              end;
          end;
          Module := D;
          Extension := '.pt3';
          Exit(True);
        except
          on E: EArgumentException do
            Decoder := nil;
        end;
      end;
    if Signature(Data, 0, 'PSID') or Signature(Data, 0, 'RSID') then
      Add('.sid');
    if Signature(Data, 0, 'CHIPTUNE') then
      Add('.chi');
    if Signature(Data, 0, 'PSC') or Signature(Data, 0, 'PRO SOUND CREATOR') then
      Add('.psc');
    if (Data[1] = Ord('G')) and (Data[2] = Ord('T')) and (Data[3] = Ord('R')) then
      Add('.gtr');
    if Signature(Data, 0, 'FAST TRACKER') or Signature(Data, 0, 'FastTracker') then
      Add('.ftc');
    if (Data[0] > 0) and (Data[0] <= 32) then
    begin
   // ASC v1: tempo/loop, three relative tables, position count and indices.
      if (Data[8] > 0) and (Data[1] < Data[8]) and (9 + Integer(Data[8]) <= Length(Data)) and PointerAt(2, 9 + Integer(Data[8])) and PointerAt(4) and PointerAt(6) then
        Add('.asc');
      if (Data[7] > 0) and (8 + Integer(Data[7]) <= Length(Data)) and PointerAt(1, 8 + Integer(Data[7])) and PointerAt(3) and PointerAt(5) then
        Add('.as0');
      if (Length(Data) >= 100) and (Data[1] > 0) and (Data[2] < Data[1]) and PointerAt(67, 99 + Integer(Data[1])) then
        Add('.pt1');
      if (Length(Data) >= 132) and (Data[1] > 0) and (Data[2] < Data[1]) and PointerAt(99, 131 + Integer(Data[1])) then
        Add('.pt2');
      if (Length(Data) >= 27) and PointerAt(1, 27) and PointerAt(3, 27) and PointerAt(5, 27) then
        Add('.stc');
      if PointerAt(1, 10) and PointerAt(3, 10) and PointerAt(5, 10) and PointerAt(7, 10) then
        Add('.stp');
    end;
    if (Length(Data) >= 140) and PointerAt(71, 140) and PointerAt(74, 140) and (Data[73] > 0) and (Data[73] < 32) then
      Add('.psc');
    if (Length(Data) >= 214) and (Data[69] > 0) and (Data[69] <= 32) and PointerAt(75, 214) then
      Add('.ftc');
    if (LE16(Data, 0) >= 8) and PointerAt(0, 8) and PointerAt(2, 8) and PointerAt(4, 8) and PointerAt(6, 8) then
      Add('.psm');
    if (Length(Data) >= 12) and (LE16(Data, 2) >= 10) and (LE16(Data, 4) > LE16(Data, 2)) and (LE16(Data, 6) > LE16(Data, 4)) and (LE16(Data, 8) > LE16(Data, 6)) then
      Add('.sqt');
    for var Ext in Candidates do
    begin
      try
        Decoder := TTuneDecoders.OpenData(Data, Ext);
        Module := Copy(Data);
        Extension := Ext;
        Exit(True);
      except
        on E: EArgumentException do
          Decoder := nil;
        on E: ERangeError do
          Decoder := nil;
        on E: ENotSupportedException do
          Decoder := nil;
      end;
    end;
  finally
    Candidates.Free;
  end;
end;

constructor TTRDOSDecoder.Create(const Data: TBytes; SCL: Boolean);
var
  Entries, Cursor, EntrySize, Directory, Skipped: Integer;
  Songs: TList<TDiskSong>;
begin
  inherited Create;
  Skipped := 0;
  Songs := TList<TDiskSong>.Create;
  try
    if SCL then
    begin
      RequireBytes(Data, 0, 9);
      if not Signature(Data, 0, 'SINCLAIR') or (Data[8] = 0) then
        raise EArgumentException.Create('Invalid SCL header');
      Entries := Data[8];
      EntrySize := 14;
      Directory := 9;
      RequireBytes(Data, Directory, Entries * EntrySize);
      Cursor := 9 + Entries * 14;
      var EndOffset := Cursor;
      for var I := 0 to Entries - 1 do
        Inc(EndOffset, Integer(Data[Directory + I * EntrySize + 13]) * 256);
      RequireBytes(Data, EndOffset, 4);
      if Length(Data) <> EndOffset + 4 then
        raise EArgumentException.Create('Invalid SCL payload size');
      var Sum: UInt64 := 0;
      for var I := 0 to EndOffset - 1 do
        Inc(Sum, Data[I]);
      if LE32(Data, EndOffset) <> Cardinal(Sum and $FFFFFFFF) then
        raise EArgumentException.Create('Invalid SCL checksum');
      FInfo.FormatName := 'SCL';
    end
    else
    begin
      RequireBytes(Data, 0, 4096);
      if (Length(Data) mod 256 <> 0) or (Data[$8E7] <> $10) or not (Data[$8E3] in [$16..$19]) then
        raise EArgumentException.Create('Invalid TR-DOS disk header');
      if Length(Data) > 655360 then
        raise EArgumentException.Create('TRD exceeds 640 KiB');
      Entries := 128;
      EntrySize := 16;
      Directory := 0;
      Cursor := 0;
      FInfo.FormatName := 'TRD';
      FInfo.Title := TextField(Data, $8F5, 8);
    end;
    var Used: TArray<Boolean>;
    SetLength(Used, Length(Data) div 256);
    if not SCL then
      for var I := 0 to 15 do
        Used[I] := True;
    for var I := 0 to Entries - 1 do
    begin
      var Entry := Directory + I * EntrySize;
      if not SCL and (Data[Entry] = 0) then
        Break;
      var Size := Integer(Data[Entry + 13]) * 256;
      var Start := Cursor;
      if SCL then
        Inc(Cursor, Size)
      else
      begin
        if Data[Entry] = 1 then
          Continue;
        if Data[Entry + 14] >= 16 then
          raise EArgumentException.Create('Invalid TRD sector');
        Start := (Integer(Data[Entry + 15]) * 16 + Data[Entry + 14]) * 256;
      end;
      RequireBytes(Data, Start, Size);
      if Size = 0 then
        Continue;
      if not SCL then
        for var Sector := Start div 256 to (Start + Size) div 256 - 1 do
        begin
          if Used[Sector] then
            raise EArgumentException.Create('Overlapping TRD files');
          Used[Sector] := True;
        end;
      var FileLength := Integer(LE16(Data, Entry + 11));
      if (FileLength <= 0) or (FileLength > Size) then
        FileLength := Size;
      var FileData := Copy(Data, Start, FileLength);
      var Song: TDiskSong;
      var Decoder: ITuneDecoder;
      var Found := FindMusic(FileData, Song.Data, Song.Extension, Decoder);
      if not Found and (FileLength < Size) then
        Found := FindMusic(Copy(Data, Start, Size), Song.Data, Song.Extension, Decoder);
      if Found then
      begin
        Song.Name := TextField(Data, Entry, 8) + '.' + Char(Data[Entry + 8]);
        Song.Info := Decoder.GetInfo;
        Songs.Add(Song);
      end
      else
        Inc(Skipped);
    end;
    if Songs.Count = 0 then
      raise EArgumentException.Create('No supported music found in TR-DOS image');
    FSongs := Songs.ToArray;
    FInfo.TrackCount := Length(FSongs);
    FInfo.SampleRate := 44100;
    FInfo.Channels := 2;
    FInfo.DefaultTrack := 0;
    SetLength(FInfo.TrackNames, FInfo.TrackCount);
    SetLength(FInfo.TrackDurations, FInfo.TrackCount);
    for var I := 0 to FInfo.TrackCount - 1 do
    begin
      FInfo.TrackNames[I] := FSongs[I].Name + ' (' + FSongs[I].Info.FormatName + ')';
      if FSongs[I].Info.Title <> '' then
        FInfo.TrackNames[I] := FInfo.TrackNames[I] + ' — ' + FSongs[I].Info.Title;
      FInfo.TrackDurations[I] := -1;
      if Length(FSongs[I].Info.TrackDurations) > 0 then
        FInfo.TrackDurations[I] := FSongs[I].Info.TrackDurations[0];
    end;
    FInfo.Details := Format('%d music files; %d non-music or unsupported files', [FInfo.TrackCount, Skipped]);
    SelectTrack(0);
  finally
    Songs.Free;
  end;
end;

function TTRDOSDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TTRDOSDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FSongs)) then
    raise EArgumentOutOfRangeException.Create('TR-DOS music file');
  FBase := TTuneDecoders.OpenData(FSongs[Index].Data, FSongs[Index].Extension);
  FBase.SelectTrack(0);
end;

function TTRDOSDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  Result := FBase.Render(Samples, Frames);
end;

function OpenTRD(const Data: TBytes): ITuneDecoder;
begin
  Result := TTRDOSDecoder.Create(Data, False);
end;

function OpenSCL(const Data: TBytes): ITuneDecoder;
begin
  Result := TTRDOSDecoder.Create(Data, True);
end;

initialization
  TTuneDecoders.RegisterFormat('.trd', 'TR-DOS disk image', OpenTRD);
  TTuneDecoders.RegisterFormat('.scl', 'SINCLAIR disk archive', OpenSCL);

end.

