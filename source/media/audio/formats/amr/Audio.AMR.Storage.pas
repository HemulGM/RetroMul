unit Audio.AMR.Storage;

interface

uses
  System.Classes, System.SysUtils, Audio.AMR.NB, Audio.AMR.WB;

{$SCOPEDENUMS ON}

type
  TAMRCodec = (Narrowband, Wideband);

  // Reads RFC 4867 storage from the stream's current position. The caller owns
  // the stream and keeps it open for the lifetime of the reader.
  TAMRStorageReader = class sealed
  private
    FSource: TStream;
    FCodec: TAMRCodec;
    FChannels: Integer;
    FSampleRate: Integer;
    FSamplesPerBlock: Integer;
    FNBDecoders: TArray<TAMRNBDecoder>;
    FWBDecoders: TArray<TAMRWBDecoder>;
    FFrames: TArray<TBytes>;
    procedure ReadHeader;
  public
    constructor Create(Source: TStream);
    destructor Destroy; override;
    // Returns 20 ms of signed PCM, interleaved in file channel order.
    // False indicates clean EOF before the next block.
    function ReadBlock(out PCM: TArray<SmallInt>): Boolean;
    // Requires a seekable stream and leaves the read position unchanged.
    function CountRemainingBlocks: Integer;
    property Codec: TAMRCodec read FCodec;
    property Channels: Integer read FChannels;
    property SampleRate: Integer read FSampleRate;
    property SamplesPerBlock: Integer read FSamplesPerBlock;
  end;

function DetectAMRStorage(const Data: TBytes; out Codec: TAMRCodec): Boolean;

function AMRStorageFrameSize(Header: Byte; Codec: TAMRCodec): Integer;

implementation

const
  NBMagic: AnsiString = '#!AMR'#10;
  WBMagic: AnsiString = '#!AMR-WB'#10;
  NBMultiMagic: AnsiString = '#!AMR_MC1.0'#10;
  WBMultiMagic: AnsiString = '#!AMR-WB_MC1.0'#10;

{$B-}

function DetectAMRStorage(const Data: TBytes; out Codec: TAMRCodec): Boolean;

  function Matches(const Magic: AnsiString): Boolean;
  begin
    Result := (Length(Data) >= Length(Magic)) and CompareMem(@Data[0], PAnsiChar(Magic), Length(Magic));
  end;

begin
  Result := True;
  if Matches(NBMagic) or Matches(NBMultiMagic) then
    Codec := TAMRCodec.Narrowband
  else if Matches(WBMagic) or Matches(WBMultiMagic) then
    Codec := TAMRCodec.Wideband
  else
  begin
    Codec := Default(TAMRCodec);
    Result := False;
  end;
end;

function AMRStorageFrameSize(Header: Byte; Codec: TAMRCodec): Integer;
begin
  if Codec = TAMRCodec.Narrowband then
    Result := TAMRNBDecoder.StorageFrameSize(Header)
  else
    Result := TAMRWBDecoder.StorageFrameSize(Header);
end;

constructor TAMRStorageReader.Create(Source: TStream);
begin
  inherited Create;
  if Source = nil then
    raise EArgumentNilException.Create('Source');
  FSource := Source;
  ReadHeader;
  SetLength(FFrames, FChannels);

  case FCodec of
    TAMRCodec.Narrowband:
      begin
        FSampleRate := AMRNBSampleRate;
        FSamplesPerBlock := AMRNBSamplesPerFrame;
        SetLength(FNBDecoders, FChannels);
        for var Channel := 0 to FChannels - 1 do
          FNBDecoders[Channel] := TAMRNBDecoder.Create;
      end;
    TAMRCodec.Wideband:
      begin
        FSampleRate := AMRWBSampleRate;
        FSamplesPerBlock := AMRWBSamplesPerFrame;
        SetLength(FWBDecoders, FChannels);
        for var Channel := 0 to FChannels - 1 do
          FWBDecoders[Channel] := TAMRWBDecoder.Create;
      end;
  end;
end;

destructor TAMRStorageReader.Destroy;
begin
  for var Decoder in FNBDecoders do
    Decoder.Free;
  for var Decoder in FWBDecoders do
    Decoder.Free;
  inherited;
end;

procedure TAMRStorageReader.ReadHeader;
var
  Magic: AnsiString;
  B: Byte;
  ChannelDescription: array[0..3] of Byte;
begin
  repeat
    if (Length(Magic) >= Length(WBMultiMagic)) or (FSource.Read(B, 1) <> 1) then
      raise EReadError.Create('Invalid AMR storage header');
    Magic := Magic + AnsiChar(B);
  until B = 10;

  if (Magic = NBMagic) or (Magic = NBMultiMagic) then
    FCodec := TAMRCodec.Narrowband
  else if (Magic = WBMagic) or (Magic = WBMultiMagic) then
    FCodec := TAMRCodec.Wideband
  else
    raise EReadError.Create('Invalid AMR storage magic');

  FChannels := 1;
  if (Magic = NBMultiMagic) or (Magic = WBMultiMagic) then
  begin
    FSource.ReadBuffer(ChannelDescription, SizeOf(ChannelDescription));
    FChannels := ChannelDescription[3] and $0F;
    if FChannels = 0 then
      raise EReadError.Create('Invalid AMR channel count');
  end;
end;

function TAMRStorageReader.ReadBlock(out PCM: TArray<SmallInt>): Boolean;
var
  Header: Byte;
  Size: Integer;
  Narrow: TAMRNBPCM;
  Wide: TAMRWBPCM;
begin
  for var Channel := 0 to FChannels - 1 do
  begin
    if FSource.Read(Header, 1) <> 1 then
    begin
      if Channel = 0 then
        Exit(False);
      raise EReadError.Create('Incomplete AMR frame block');
    end;

    Size := AMRStorageFrameSize(Header, FCodec);
    if Size = 0 then
      raise EReadError.Create('Reserved AMR frame type');
    SetLength(FFrames[Channel], Size);
    FFrames[Channel][0] := Header;
    if Size > 1 then
      FSource.ReadBuffer(FFrames[Channel][1], Size - 1);
  end;

  SetLength(PCM, FChannels * FSamplesPerBlock);
  for var Channel := 0 to FChannels - 1 do
    if FCodec = TAMRCodec.Narrowband then
    begin
      FNBDecoders[Channel].DecodeStorageFrame(FFrames[Channel], Narrow);
      for var I := Low(Narrow) to High(Narrow) do
        PCM[I * FChannels + Channel] := Narrow[I];
    end
    else
    begin
      FWBDecoders[Channel].DecodeStorageFrame(FFrames[Channel], Wide);
      for var I := Low(Wide) to High(Wide) do
        PCM[I * FChannels + Channel] := Wide[I];
    end;
  Result := True;
end;

function TAMRStorageReader.CountRemainingBlocks: Integer;
begin
  Result := 0;
  var Start := FSource.Position;
  try
    var EndPosition := FSource.Size;
    while FSource.Position < EndPosition do
    begin
      for var Channel := 1 to FChannels do
      begin
        var Header: Byte;
        FSource.ReadBuffer(Header, 1);
        var Size := AMRStorageFrameSize(Header, FCodec);
        if (Size = 0) or (Size - 1 > EndPosition - FSource.Position) then
          raise EReadError.Create('Invalid or truncated AMR frame');
        FSource.Seek(Size - 1, soCurrent);
      end;
      Inc(Result);
    end;
  finally
    FSource.Position := Start;
  end;
end;

end.

