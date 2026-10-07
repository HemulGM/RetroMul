unit RetroTune.Decoder.GYM;

interface

implementation

uses
  System.SysUtils, System.Classes, System.ZLib, RetroTune.Decoder,
  RetroTune.Decoder.VGM, RetroTune.Binary;

type
  TGYMDecoder = class(TInterfacedObject, ITuneDecoder)
  private
    FBase: ITuneDecoder;
    FInfo: TTuneInfo;
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TTuneInfo;
    procedure SelectTrack(Index: Integer);
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer;
  end;

constructor TGYMDecoder.Create(const Data: TBytes);
var
  Header, Body: TBytes;
begin
  inherited Create;
  RequireBytes(Data, 0, 1);
  var Offset := 0;
  var PackedLength: Cardinal := 0;
  if (Length(Data) >= 4) and (TEncoding.ASCII.GetString(Data, 0, 4) = 'GYMX') then
  begin
    RequireBytes(Data, 0, 428);
    Offset := 428;
    FInfo.Title := TextField(Data, 4, 32);
    FInfo.CopyrightText := TextField(Data, 68, 32);
    PackedLength := LE32(Data, 424);
  end;
  Body := Copy(Data, Offset, Length(Data) - Offset);
  if PackedLength <> 0 then
  begin
    if PackedLength > 16 * 1024 * 1024 then
      raise EArgumentException.Create('GYM data exceeds 16 MiB');
    var Source := TBytesStream.Create(Body);
    try
      var Inflate := TZDecompressionStream.Create(Source);
      try
        SetLength(Body, PackedLength);
        Inflate.ReadBuffer(Body[0], PackedLength);
        var Extra: Byte;
        if Inflate.Read(Extra, 1) <> 0 then
          raise EArgumentException.Create('Invalid GYM packed length');
      finally
        Inflate.Free;
      end;
    finally
      Source.Free;
    end;
  end;
  // GYM logs writes per 60 Hz frame. DAC samples are distributed across it.
  var Output := TMemoryStream.Create;
  try
    SetLength(Header, $40);
    Header[0] := Ord('V');
    Header[1] := Ord('g');
    Header[2] := Ord('m');
    Header[3] := Ord(' ');
    Header[8] := $50;
    Header[9] := 1;
    var Clock: Cardinal := 3579545;
    Move(Clock, Header[$C], 4);
    Clock := 7670454;
    Move(Clock, Header[$2C], 4);
    Header[$28] := 9;
    Header[$2A] := 16;
    Header[$34] := $C;
    Output.WriteBuffer(Header[0], Length(Header));
    Offset := 0;
    while Offset < Length(Body) do
    begin
      var DAC: TBytes := nil;
      var HasFrame := False;
      while Offset < Length(Body) do
      begin
        var Command := Body[Offset];
        Inc(Offset);
        if Command = 0 then
        begin
          HasFrame := True;
          Break;
        end;
        case Command of
          1, 2:
            begin
              RequireBytes(Body, Offset, 2);
              if (Command = 1) and (Body[Offset] = $2A) then
                DAC := DAC + [Body[Offset + 1]]
              else
              begin
                var VGMCommand: Byte := $51 + Command;
                Output.WriteBuffer(VGMCommand, 1);
                Output.WriteBuffer(Body[Offset], 2);
              end;
              Inc(Offset, 2);
            end;
          3:
            begin
              RequireBytes(Body, Offset, 1);
              var VGMCommand: Byte := $50;
              Output.WriteBuffer(VGMCommand, 1);
              Output.WriteBuffer(Body[Offset], 1);
              Inc(Offset);
            end;
        else
          raise EArgumentException.CreateFmt('Invalid GYM command $%.2x', [Command]);
        end;
      end;
      if not HasFrame then
        raise EArgumentException.Create('Truncated GYM frame');
      if Length(DAC) = 0 then
      begin
        var Wait: Byte := $62;
        Output.WriteBuffer(Wait, 1);
      end
      else
        for var J := 0 to High(DAC) do
        begin
          var WriteDAC: array[0..2] of Byte;
          WriteDAC[0] := $52;
          WriteDAC[1] := $2A;
          WriteDAC[2] := DAC[J];
          Output.WriteBuffer(WriteDAC, 3);
          var Wait: Byte := $61;
          Output.WriteBuffer(Wait, 1);
          var Samples: Word := (Int64(J + 1) * 735 div Length(DAC)) - (Int64(J) * 735 div Length(DAC));
          Output.WriteBuffer(Samples, 2);
        end;
      if Output.Size > 16 * 1024 * 1024 then
        raise EArgumentException.Create('Expanded GYM exceeds 16 MiB');
    end;
    var EndCommand: Byte := $66;
    Output.WriteBuffer(EndCommand, 1);
    var Converted: TBytes;
    SetLength(Converted, Output.Size);
    Move(Output.Memory^, Converted[0], Length(Converted));
    var EOFOffset: Cardinal := Length(Converted) - 4;
    Move(EOFOffset, Converted[4], 4);
    FBase := TVGMDecoder.Create(Converted);
  finally
    Output.Free;
  end;
  FInfo.TrackDurations := FBase.GetInfo.TrackDurations;
  FInfo.TrackDurations := FBase.GetInfo.TrackDurations;
  FInfo.FormatName := 'GYM';
  FInfo.Details := 'Mega Drive / YM2612 / SN76489';
  FInfo.TrackCount := 1;
  FInfo.SampleRate := 44100;
  FInfo.Channels := 2;
end;

function TGYMDecoder.GetInfo: TTuneInfo;
begin
  Result := FInfo;
end;

procedure TGYMDecoder.SelectTrack(Index: Integer);
begin
  FBase.SelectTrack(Index);
end;

function TGYMDecoder.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  Result := FBase.Render(Samples, Frames);
end;

function CreateGYM(const Data: TBytes): ITuneDecoder;
begin
  Result := TGYMDecoder.Create(Data);
end;

initialization
  TTuneDecoders.RegisterFormat('.gym', 'Mega Drive GYM', CreateGYM);

end.
