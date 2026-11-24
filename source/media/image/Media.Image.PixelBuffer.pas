unit Media.Image.PixelBuffer;

interface

type
  IImagePixelBuffer = interface
    ['{184519ED-1D55-4712-9ED2-69CA2AEA79F2}']
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetTransparent: Boolean;
    function GetDisposed: Boolean;
    function GetContentVersion: UInt64;
    function Pixel(X, Y: Integer): Cardinal;
    function PixelPremultiplied(X, Y: Integer): Cardinal;
    procedure SetPixelPremultiplied(X, Y: Integer; Color: Cardinal);
    procedure SetPixel(X, Y: Integer; Color: Cardinal);
    // Shared, read-only view valid for immediate rendering on the VM thread.
    function SnapshotPremultiplied: TArray<Cardinal>;
    procedure Dispose;
    // Copies a fully in-bounds rectangle, applying the destination's opacity rule.
    function TryCopyPremultiplied(const Source: IImagePixelBuffer; SourceX, SourceY, DestX, DestY, Width, Height: Integer): Boolean;
    // Stores a tightly packed renderer result, with SetPixelPremultiplied semantics.
    function TryWritePremultiplied(const Pixels: TArray<Cardinal>; X, Y, Width, Height: Integer): Boolean;
    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    property Transparent: Boolean read GetTransparent;
    property Disposed: Boolean read GetDisposed;
    // Compare versions from snapshots of the same storage on the VM thread.
    property ContentVersion: UInt64 read GetContentVersion;
  end;

  IImagePixelPool = interface
    ['{C03B13BC-BA3D-4247-82ED-987A6082B871}']
    function Allocate(Width, Height: Integer; Transparent: Boolean; Color: Cardinal): IImagePixelBuffer;
    procedure ReleasePixels(Count: Integer);
  end;

function CreateImagePixelPool(PixelLimit: Integer): IImagePixelPool;

function PremultiplyBitmapColor(Color: Cardinal; Transparent: Boolean): Cardinal;

function UnpremultiplyBitmapColor(Color: Cardinal): Cardinal;

function BlendPremultiplied(Dest, Source: Cardinal): Cardinal;

implementation

type
  TImagePixelPool = class(TInterfacedObject, IImagePixelPool)
  private
    FUsed, FLimit: Integer;
  public
    constructor Create(PixelLimit: Integer);
    function Allocate(Width, Height: Integer; Transparent: Boolean; Color: Cardinal): IImagePixelBuffer;
    procedure ReleasePixels(Count: Integer);
  end;

  TImagePixelBuffer = class(TInterfacedObject, IImagePixelBuffer)
  private
    FOwner: IImagePixelPool;
    FWidth, FHeight: Integer;
    FTransparent, FDisposed: Boolean;
    FContentVersion: UInt64;
    FPixels: TArray<Cardinal>;
  public
    constructor Create(const Owner: IImagePixelPool; Width, Height: Integer; Transparent: Boolean; Color: Cardinal);
    destructor Destroy; override;
    function GetWidth: Integer;
    function GetHeight: Integer;
    function GetTransparent: Boolean;
    function GetDisposed: Boolean;
    function GetContentVersion: UInt64;
    function Pixel(X, Y: Integer): Cardinal;
    function PixelPremultiplied(X, Y: Integer): Cardinal;
    procedure SetPixelPremultiplied(X, Y: Integer; Color: Cardinal);
    procedure SetPixel(X, Y: Integer; Color: Cardinal);
    function SnapshotPremultiplied: TArray<Cardinal>;
    procedure Dispose;
    function TryCopyPremultiplied(const Source: IImagePixelBuffer; SourceX, SourceY, DestX, DestY, Width, Height: Integer): Boolean;
    // Stores a tightly packed renderer result, with SetPixelPremultiplied semantics.
    function TryWritePremultiplied(const Pixels: TArray<Cardinal>; X, Y, Width, Height: Integer): Boolean;
  end;

function CreateImagePixelPool(PixelLimit: Integer): IImagePixelPool;
begin
  Result := TImagePixelPool.Create(PixelLimit);
end;

constructor TImagePixelPool.Create(PixelLimit: Integer);
begin
  inherited Create;
  FLimit := PixelLimit;
end;

function TImagePixelPool.Allocate(Width, Height: Integer; Transparent: Boolean; Color: Cardinal): IImagePixelBuffer;
var
  Count: Int64;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  Count := Int64(Width) * Height;
  if Count > FLimit - FUsed then
    Exit;
  Result := TImagePixelBuffer.Create(Self, Width, Height, Transparent, Color);
  Inc(FUsed, Integer(Count));
end;

procedure TImagePixelPool.ReleasePixels(Count: Integer);
begin
  Dec(FUsed, Count);
end;

{ AVM1 bitmap channel conversion and Flash rounding table }
function PremultiplyBitmapColor(Color: Cardinal; Transparent: Boolean): Cardinal;
var
  Alpha, Red, Green, Blue: Cardinal;
begin
  if not Transparent then
    Exit(Color or $FF000000);
  Alpha := Color shr 24;
  if Alpha = 255 then
    Exit(Color);
  Red := (((Color shr 16) and $FF) * Alpha + 127) div 255;
  Green := (((Color shr 8) and $FF) * Alpha + 127) div 255;
  Blue := ((Color and $FF) * Alpha + 127) div 255;
  Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

function UnpremultiplyBitmapColor(Color: Cardinal): Cardinal;
const
  Factor: array[0..255] of Cardinal = (
    0, 16678912, 8339456, 5559638, 4169728, 3335783, 2779819, 2386603, 2086230, 1855488,
    1667892, 1518251, 1391151, 1285234, 1193302, 1111928, 1043895, 981113, 927744, 879275,
    834621, 795535, 759126, 726358, 695839, 668183, 642538, 618737, 596651, 576171,
    555964, 538706, 522104, 506319, 490557, 477321, 464038, 451353, 439544, 428244,
    417582, 407500, 397768, 388535, 379630, 371117, 363179, 355235, 348050, 340965,
    334052, 327038, 321269, 315077, 309159, 303586, 298189, 293092, 287981, 283080,
    278251, 273892, 269268, 265179, 261087, 256971, 253160, 249322, 245508, 242164,
    238575, 235245, 231859, 228848, 225785, 222712, 219616, 216827, 213985, 211432,
    208835, 206075, 203750, 201196, 198895, 196223, 194301, 191987, 189686, 187636,
    185559, 183426, 181453, 179444, 177638, 175855, 174054, 171948, 170489, 168695,
    166889, 165365, 163519, 162045, 160508, 158970, 157429, 156150, 154610, 153081,
    151803, 150511, 148986, 147709, 146420, 145116, 143868, 142586, 141545, 140277,
    139194, 137957, 136954, 135676, 134652, 133621, 132604, 131577, 130552, 129527,
    128508, 127476, 126451, 125432, 124670, 123645, 122818, 121847, 121082, 120060,
    119288, 118263, 117502, 116720, 115967, 115195, 114424, 113655, 112893, 112125,
    111356, 110563, 109811, 109048, 108287, 107766, 107004, 106236, 105724, 104953,
    104434, 103676, 102904, 102375, 101879, 101119, 100604, 99834, 99321, 98813,
    98112, 97533, 97019, 96509, 95994, 95486, 94713, 94185, 93689, 93179,
    92667, 92149, 91643, 91129, 90621, 90068, 89597, 89342, 88829, 88318,
    87804, 87294, 87034, 86523, 85994, 85499, 85245, 84732, 84222, 83956,
    83450, 82937, 82685, 82173, 81840, 81405, 80889, 80638, 80127, 79862,
    79354, 79103, 78590, 78332, 78077, 77565, 77308, 76795, 76541, 76284,
    75766, 75518, 75262, 74748, 74493, 74238, 73691, 73470, 73214, 72959,
    72447, 72189, 71935, 71671, 71166, 70911, 70651, 70399, 70140, 69886,
    69615, 69116, 68861, 68603, 68350, 68093, 67839, 67576, 67326, 67070,
    66813, 66556, 66302, 66046, 65791, 65408);
var
  Alpha, Scale, Red, Green, Blue: Cardinal;
begin
  Alpha := Color shr 24;
  Scale := Factor[Alpha];
  Red := ((((Color shr 16) and $FF) * Scale + $8000) shr 16) and $FF;
  Green := ((((Color shr 8) and $FF) * Scale + $8000) shr 16) and $FF;
  Blue := (((Color and $FF) * Scale + $8000) shr 16) and $FF;
  Result := (Alpha shl 24) or (Red shl 16) or (Green shl 8) or Blue;
end;

constructor TImagePixelBuffer.Create(const Owner: IImagePixelPool; Width, Height: Integer; Transparent: Boolean; Color: Cardinal);
var
  Index: Integer;
begin
  inherited Create;
  FWidth := Width;
  FHeight := Height;
  FTransparent := Transparent;
  SetLength(FPixels, Width * Height);
  Color := PremultiplyBitmapColor(Color, Transparent);
  for Index := 0 to High(FPixels) do
    FPixels[Index] := Color;
  FOwner := Owner;
end;

destructor TImagePixelBuffer.Destroy;
begin
  Dispose;
  inherited Destroy;
end;

function TImagePixelBuffer.GetWidth: Integer;
begin
  Result := FWidth;
end;

function TImagePixelBuffer.GetHeight: Integer;
begin
  Result := FHeight;
end;

function TImagePixelBuffer.GetTransparent: Boolean;
begin
  Result := FTransparent;
end;

function TImagePixelBuffer.GetDisposed: Boolean;
begin
  Result := FDisposed;
end;

function TImagePixelBuffer.GetContentVersion: UInt64;
begin
  Result := FContentVersion;
end;

function TImagePixelBuffer.Pixel(X, Y: Integer): Cardinal;
begin
  Result := UnpremultiplyBitmapColor(PixelPremultiplied(X, Y));
end;

procedure TImagePixelBuffer.SetPixel(X, Y: Integer; Color: Cardinal);
begin
  if (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight) then
  begin
    FPixels[Y * FWidth + X] := PremultiplyBitmapColor(Color, FTransparent);
    Inc(FContentVersion);
  end;
end;

function BlendPremultiplied(Dest, Source: Cardinal): Cardinal;
var
  InverseAlpha, Shift, Channel: Cardinal;
begin
  InverseAlpha := 256 - (Source shr 24);
  Result := 0;
  for Shift in [0, 8, 16, 24] do
  begin
    Channel := ((Source shr Shift) and $FF) +
      ((((Dest shr Shift) and $FF) * InverseAlpha) shr 8);
    Result := Result or ((Channel and $FF) shl Shift);
  end;
end;

function TImagePixelBuffer.PixelPremultiplied(X, Y: Integer): Cardinal;
begin
  Result := 0;
  if (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight) then
    Result := FPixels[Y * FWidth + X];
end;

procedure TImagePixelBuffer.SetPixelPremultiplied(X, Y: Integer; Color: Cardinal);
begin
  if (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight) then
  begin
    if not FTransparent then
      Color := Color or $FF000000;
    FPixels[Y * FWidth + X] := Color;
    Inc(FContentVersion);
  end;
end;

function TImagePixelBuffer.SnapshotPremultiplied: TArray<Cardinal>;
begin
  Result := FPixels;
end;

function TImagePixelBuffer.TryCopyPremultiplied(const Source: IImagePixelBuffer; SourceX, SourceY, DestX, DestY, Width, Height: Integer): Boolean;
var
  SourcePixels: TArray<Cardinal>;
  SourceWidth, SourceHeight, Row, Step, RowsLeft, Column: Integer;
  Input, Output: PCardinal;
  MakeOpaque: Boolean;
begin
  Result := False;
  if (Source = nil) or FDisposed or Source.Disposed or (Width <= 0) or (Height <= 0) or
    (SourceX < 0) or (SourceY < 0) or (DestX < 0) or (DestY < 0) or
    (DestX > FWidth - Width) or (DestY > FHeight - Height) then
    Exit;
  SourceWidth := Source.Width;
  SourceHeight := Source.Height;
  if (SourceX > SourceWidth - Width) or (SourceY > SourceHeight - Height) then
    Exit;
  SourcePixels := Source.SnapshotPremultiplied;
  if Int64(SourceWidth) * SourceHeight <> Length(SourcePixels) then
    Exit;

  // Move handles horizontal overlap. For vertical overlap read the lower
  // rows first when the destination starts below the source.
  Row := 0;
  Step := 1;
  if (SourcePixels = FPixels) and (DestY > SourceY) then
  begin
    Row := Height - 1;
    Step := -1;
  end;
  MakeOpaque := not FTransparent and Source.Transparent;
  for RowsLeft := Height downto 1 do
  begin
    Input := @SourcePixels[(SourceY + Row) * SourceWidth + SourceX];
    Output := @FPixels[(DestY + Row) * FWidth + DestX];
    if MakeOpaque then
      for Column := 1 to Width do
      begin
        Output^ := UnpremultiplyBitmapColor(Input^) or $FF000000;
        Inc(Input);
        Inc(Output);
      end
    else
      Move(Input^, Output^, NativeInt(Width) * SizeOf(Cardinal));
    Inc(Row, Step);
  end;
  Inc(FContentVersion, Width * Height);
  Result := True;
end;

function TImagePixelBuffer.TryWritePremultiplied(const Pixels: TArray<Cardinal>; X, Y, Width, Height: Integer): Boolean;
var
  Row, Column, DestOffset, SourceOffset: Integer;
  Count: Int64;
begin
  Result := False;
  Count := Int64(Width) * Height;
  if FDisposed or (Width <= 0) or (Height <= 0) or (X < 0) or (Y < 0) or
    (X > FWidth - Width) or (Y > FHeight - Height) or
    (Count <> Length(Pixels)) or (Pixels = FPixels) then
    Exit;

  DestOffset := Y * FWidth + X;
  if FTransparent and (Width = FWidth) then
    Move(Pixels[0], FPixels[DestOffset], NativeInt(Count) * SizeOf(Cardinal))
  else
  begin
    SourceOffset := 0;
    for Row := 0 to Height - 1 do
    begin
      if FTransparent then
        Move(Pixels[SourceOffset], FPixels[DestOffset], NativeInt(Width) * SizeOf(Cardinal))
      else
        for Column := 0 to Width - 1 do
          FPixels[DestOffset + Column] := Pixels[SourceOffset + Column] or $FF000000;
      Inc(SourceOffset, Width);
      Inc(DestOffset, FWidth);
    end;
  end;
  Inc(FContentVersion, UInt64(Count));
  Result := True;
end;

procedure TImagePixelBuffer.Dispose;
begin
  if FDisposed then
    Exit;
  FDisposed := True;
  Inc(FContentVersion);
  if FOwner <> nil then
    FOwner.ReleasePixels(Length(FPixels));
  FOwner := nil;
  FPixels := nil;
  FWidth := 0;
  FHeight := 0;
end;

end.

