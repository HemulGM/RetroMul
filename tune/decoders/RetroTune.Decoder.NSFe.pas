unit RetroTune.Decoder.NSFe;

interface

uses
  System.SysUtils, RetroTune.Decoder;

function OpenNESMusic(const Data: TBytes; Container: Boolean): ITuneDecoder;

implementation

uses
  System.Math, RetroTune.Binary, RetroTune.Decoder.NSF;

type
  TNESMetadataDecoder = class(TInterfacedObject, ITuneDecoder)
  public
    Base: ITuneDecoder;
    Info: TTuneInfo;
    Playlist: TBytes;
    Times, Fades: TArray<Integer>;
    Position, EndFrame, FadeFrame: Int64;
    Ready: Boolean;
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

function TNESMetadataDecoder.GetInfo: TTuneInfo;
begin
  Result := Info;
end;

procedure TNESMetadataDecoder.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= Info.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid NES music track');
  var Physical := Integer(Playlist[Index]);
  Base.SelectTrack(Physical);
  Position := 0;
  EndFrame := -1;
  FadeFrame := -1;
  Ready := True;
  if (Physical < Length(Times)) and (Times[Physical] >= 0) then
  begin
    FadeFrame := Int64(Times[Physical]) * Info.SampleRate div 1000;
    EndFrame := FadeFrame;
    if (Physical < Length(Fades)) and (Fades[Physical] > 0) then
      Inc(EndFrame, Int64(Fades[Physical]) * Info.SampleRate div 1000);
  end;
end;

function TNESMetadataDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, Info.Channels);
  if not Ready then
    raise EInvalidOpException.Create('Select a track before rendering');
  if EndFrame >= 0 then
    Frames := Min(Int64(Frames), Max(Int64(0), EndFrame - Position));
  if Frames = 0 then
    Exit(0);
  Result := Base.Render(Samples, Frames);
  if EndFrame > FadeFrame then
    for var J := 0 to Result - 1 do
      if Position + J >= FadeFrame then
        for var C := 0 to Info.Channels - 1 do
          Samples[J * Info.Channels + C] := Round(Samples[J * Info.Channels + C] *
              ((EndFrame - Position - J) / (EndFrame - FadeFrame)));
  Inc(Position, Result);
end;

function OpenNESMusic(const Data: TBytes; Container: Boolean): ITuneDecoder;
var
  Header, ProgramData, Banks, Playlist: TBytes;
  Labels, Auth: TArray<string>;
  Times, Fades: TArray<Integer>;
  Offset, Size, DefaultTrack: Integer;
  FoundInfo, FoundData, FoundEnd, Banked: Boolean;
  ID: string;
begin
  Header := nil;
  ProgramData := nil;
  Banks := nil;
  Playlist := nil;
  FoundInfo := False;
  FoundData := False;
  FoundEnd := False;
  Banked := False;
  if Container then
  begin
    RequireBytes(Data, 0, 4);
    if TEncoding.ASCII.GetString(Data, 0, 4) <> 'NSFE' then
      raise EArgumentException.Create('Invalid NSFe signature');
    SetLength(Header, $80);
    Header[0] := Ord('N');
    Header[1] := Ord('E');
    Header[2] := Ord('S');
    Header[3] := Ord('M');
    Header[4] := $1A;
    Header[5] := 1;
    Offset := 4;
  end
  else
  begin
    RequireBytes(Data, 0, $80);
    Header := Copy(Data, 0, $80);
    Size := Header[$7D] or (Integer(Header[$7E]) shl 8) or (Integer(Header[$7F]) shl 16);
    if Size = 0 then
    begin
      if (Header[5] = 2) and ((Header[$7C] and $80) <> 0) then
        raise EArgumentException.Create('NSF2 requires metadata but has no program length');
      Exit(TNSFDecoder.Create(Data));
    end;
    RequireBytes(Data, $80, Size);
    ProgramData := Copy(Data, $80, Size);
    Offset := $80 + Size;
    FoundInfo := True;
    FoundData := True;
  end;
  while Offset < Length(Data) do
  begin
    RequireBytes(Data, Offset, 8);
    var ChunkLength := LE32(Data, Offset);
    if ChunkLength > Cardinal(Length(Data) - Offset - 8) then
      raise EArgumentException.Create('Truncated NSFe chunk');
    Size := ChunkLength;
    ID := TextField(Data, Offset + 4, 4);
    Inc(Offset, 8);
    var Chunk := Copy(Data, Offset, Size);
    if ID = 'NEND' then
    begin
      FoundEnd := True;
      Break;
    end
    else if (ID = 'INFO') and Container then
    begin
      if FoundInfo then
        raise EArgumentException.Create('Duplicate NSFe INFO');
      RequireBytes(Chunk, 0, 9);
      FoundInfo := True;
      Move(Chunk[0], Header[8], 6);
      Header[$7A] := Chunk[6];
      Header[$7B] := Chunk[7];
      Header[6] := Chunk[8];
      Header[7] := 1;
      if Size >= 10 then
      begin
        if Chunk[9] >= Header[6] then
          raise EArgumentException.Create('Invalid NSFe starting track');
        Header[7] := Chunk[9] + 1;
      end;
    end
    else if (ID = 'DATA') and Container then
    begin
      if FoundData then
        raise EArgumentException.Create('Duplicate NSFe DATA');
      FoundData := True;
      ProgramData := Chunk;
    end
    else if (ID = 'BANK') and Container then
    begin
      Banked := True;
      Banks := Chunk;
    end
    else if (ID = 'NSF2') and Container then
    begin
      RequireBytes(Chunk, 0, 1);
      Header[5] := 2;
      Header[$7C] := Chunk[0];
    end
    else if ID = 'RATE' then
    begin
      RequireBytes(Chunk, 0, 2);
      Header[$6E] := Chunk[0];
      Header[$6F] := Chunk[1];
      if Size >= 4 then
      begin
        Header[$78] := Chunk[2];
        Header[$79] := Chunk[3];
      end;
    end
    else if (ID = 'auth') or (ID = 'tlbl') then
    begin
      var Strings: TArray<string> := nil;
      var Start := 0;
      for var J := 0 to Size - 1 do
        if Chunk[J] = 0 then
        begin
          Strings := Strings + [TextField(Chunk, Start, J - Start)];
          Start := J + 1;
        end;
      if Start < Size then
        Strings := Strings + [TextField(Chunk, Start, Size - Start)];
      if ID = 'auth' then
        Auth := Strings
      else
        Labels := Strings;
    end
    else if (ID = 'time') or (ID = 'fade') then
    begin
      if Size mod 4 <> 0 then
        raise EArgumentException.Create('Invalid NSFe duration chunk');
      var Values: TArray<Integer>;
      SetLength(Values, Size div 4);
      for var J := 0 to High(Values) do
        Values[J] := Integer(LE32(Chunk, J * 4));
      if ID = 'time' then
        Times := Values
      else
        Fades := Values;
    end
    else if ID = 'plst' then
      Playlist := Chunk
    else if ID = 'regn' then
    begin
      RequireBytes(Chunk, 0, 1);
      if (Chunk[0] and 3) = 0 then
        raise ENotSupportedException.Create('Dendy-only NSFe is unsupported');
      if (Chunk[0] and 1) = 0 then
        Header[$7A] := 1
      else if (Size > 1) and (Chunk[1] = 1) and ((Chunk[0] and 2) <> 0) then
        Header[$7A] := 1
      else
        Header[$7A] := 0;
    end
    else if (Length(ID) <> 4) or ((ID[1] >= 'A') and (ID[1] <= 'Z')) then
      raise ENotSupportedException.Create('Unsupported mandatory NSFe chunk: ' + ID);
    Inc(Offset, Size);
  end;
  if not FoundInfo or not FoundData or not FoundEnd or (Length(ProgramData) = 0) then
    raise EArgumentException.Create('NSFe requires INFO, DATA and NEND');
  if Banked then
    for var J := 0 to Min(7, High(Banks)) do
      Header[$70 + J] := Banks[J];
  Header[$7D] := 0;
  Header[$7E] := 0;
  Header[$7F] := 0;
  var Wrapper := TNESMetadataDecoder.Create;
  Result := Wrapper;
  Wrapper.Base := TNSFDecoder.Create(Header + ProgramData, Banked);
  Wrapper.Info := Wrapper.Base.GetInfo;
  if Container then
    Wrapper.Info.FormatName := 'NSFe';
  if Length(Auth) > 0 then
    Wrapper.Info.Title := Auth[0];
  if Length(Auth) > 1 then
    Wrapper.Info.Artist := Auth[1];
  if Length(Auth) > 2 then
    Wrapper.Info.CopyrightText := Auth[2];
  DefaultTrack := Wrapper.Info.DefaultTrack;
  if Length(Playlist) = 0 then
  begin
    SetLength(Playlist, Wrapper.Info.TrackCount);
    for var J := 0 to High(Playlist) do
      Playlist[J] := J;
  end;
  Wrapper.Info.DefaultTrack := 0;
  SetLength(Wrapper.Info.TrackNames, Length(Playlist));
  SetLength(Wrapper.Info.TrackDurations, Length(Playlist));
  for var J := High(Playlist) downto 0 do
  begin
    if Playlist[J] >= Wrapper.Info.TrackCount then
      raise EArgumentException.Create('NSFe playlist references an invalid track');
    if Playlist[J] = DefaultTrack then
      Wrapper.Info.DefaultTrack := J;
    Wrapper.Info.TrackDurations[J] := -1;
    if (Playlist[J] < Length(Times)) and (Times[Playlist[J]] >= 0) then
    begin
      var Duration: Int64 := Times[Playlist[J]];
      if (Playlist[J] < Length(Fades)) and (Fades[Playlist[J]] > 0) then
        Inc(Duration, Fades[Playlist[J]]);
      Wrapper.Info.TrackDurations[J] := Duration / 1000.0;
    end;
    if Playlist[J] < Length(Labels) then
      Wrapper.Info.TrackNames[J] := Labels[Playlist[J]];
  end;
  Wrapper.Info.TrackCount := Length(Playlist);
  Wrapper.Playlist := Playlist;
  Wrapper.Times := Times;
  Wrapper.Fades := Fades;
end;

function CreateNSFe(const Data: TBytes): ITuneDecoder;
begin
  Result := OpenNESMusic(Data, True);
end;

initialization
  TTuneDecoders.RegisterFormat('.nsfe', 'Extended Nintendo Sound Format', CreateNSFe);

end.

