unit Video.AVC.Bitstream;

interface

uses
  System.SysUtils, Core.Bitstream;

type
  TVLCNode = Core.Bitstream.TVLCNode;

  TVLCTable = Core.Bitstream.TVLCTable;

  TBitReader = Core.Bitstream.TBitReader;

function UnescapeNAL(const NAL: TBytes): TBytes;

implementation

function UnescapeNAL(const NAL: TBytes): TBytes;
begin
  Result := Core.Bitstream.UnescapeNAL(NAL, True);
end;

end.

