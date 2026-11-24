{$I PS2GSLLETypes.pasm}
{$I PS2GSLLETables.pasm}

type
  TPS2DoublePair = record
    Hi, Lo: Double;
  end;
  TPS2CoveredBits = array[0..1] of Cardinal;

var
  [Binding(0, 0)] RAM: array of Cardinal;
  [Binding(0, 1), ReadOnly] Draws: array of TPS2Draw;
  [Binding(0, 2), ReadOnly] Tiles: array of Cardinal;
  [Binding(0, 3), ReadOnly] LodTables: array of Cardinal;
  [Binding(0, 4), ReadOnly] Coordinates: array of Integer;
  [Binding(0, 5)] Results: array of Cardinal;
  [PushConstant] PC: TPS2TrianglePush;
