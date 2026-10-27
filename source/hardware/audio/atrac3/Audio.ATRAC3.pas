unit Audio.ATRAC3;
// Native ATRAC3 adapter. GPL-3.0-or-later; see LICENSE.ATRAC3.md.
interface
uses System.SysUtils,Audio.ATRAC3.Decoder;
type
 TATRAC3Decoder=class
 private
  FDecoder:TAT3Atrac3Decoder;
  FBlockAlign,FChannels,FOutputChannels,FCodingMode:Integer;
 public
  constructor Create(BlockAlign,Channels,OutputChannels,CodingMode:Integer);
  destructor Destroy;override;
  procedure Reset;
  function Decode(const Packet:TBytes):TArray<SmallInt>;
 end;
implementation
uses System.Math,Audio.ATRAC3Plus.Primitives;
constructor TATRAC3Decoder.Create(BlockAlign,Channels,OutputChannels,CodingMode:Integer);
begin
 inherited Create;
 if (BlockAlign<1) or (BlockAlign>4096) or not (Channels in [1,2]) or not (OutputChannels in [1,2]) then
  raise EATRACData.Create('ATRAC3: invalid configuration');
 FBlockAlign:=BlockAlign;FChannels:=Channels;FOutputChannels:=OutputChannels;FCodingMode:=CodingMode;
 Reset;
end;
destructor TATRAC3Decoder.Destroy;
begin FDecoder.Free;inherited end;
procedure TATRAC3Decoder.Reset;
begin
 FreeAndNil(FDecoder);FDecoder:=TAT3Atrac3Decoder.Create;
 if FDecoder.Init(FBlockAlign,FChannels,FOutputChannels,FCodingMode)<0 then
  raise EATRACData.Create('ATRAC3: decoder initialization failed');
end;
function TATRAC3Decoder.Decode(const Packet:TBytes):TArray<SmallInt>;
begin
 if Length(Packet)<>FBlockAlign then raise EATRACData.Create('ATRAC3: incorrect packet length');
 var Reader:=TATBits.Create(Packet);
 try
  FDecoder.br:=Reader;FDecoder.ctx.br:=Reader;
  if FDecoder.DecodeFrame<0 then raise EATRACData.Create('ATRAC3: invalid frame');
  SetLength(Result,1024*FOutputChannels);
  for var I:=0 to 1023 do
   for var Ch:=0 to FOutputChannels-1 do
    Result[I*FOutputChannels+Ch]:=EnsureRange(Round(FDecoder.ctx.Samples[Min(Ch,FChannels-1)][I]*32768),-32768,32767);
 finally FDecoder.br:=nil;FDecoder.ctx.br:=nil;Reader.Free end;
end;
end.
