unit FMX.SVG;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math, System.UITypes,
  System.Generics.Collections, Xml.XMLDoc, Xml.XMLIntf, FMX.Types, FMX.Controls,
  FMX.Graphics, FMX.Objects;

type
  TSvgMatrix = record
    A, B, C, D, E, F: Single;
    class function Identity: TSvgMatrix; static;
    class function Translation(X, Y: Single): TSvgMatrix; static;
    class function Scaling(X, Y: Single): TSvgMatrix; static;
    class function Rotation(Radians: Single): TSvgMatrix; static;
    class function SkewX(Radians: Single): TSvgMatrix; static;
    class function SkewY(Radians: Single): TSvgMatrix; static;
    class function FromSvg(A, B, C, D, E, F: Single): TSvgMatrix; static;
    class operator Multiply(const L, R: TSvgMatrix): TSvgMatrix;
    function TransformPoint(const P: TPointF): TPointF;
  end;

type
  TSvgLengthUnit = (sluNumber, sluPx, sluPercent, sluEm, sluEx, sluPt, sluPc, sluCm, sluMm, sluIn);

  TSvgLength = record
    Value: Single;
    units: TSvgLengthUnit;
    class function Parse(const S: string; Default: Single = 0): TSvgLength; static;
    function Resolve(Reference, FontSize: Single): Single;
  end;

type
  TSvgNumberParser = record
  private
    FText: string;
    FPos: Integer;
    procedure SkipSeparators;
  public
    class function Create(const S: string): TSvgNumberParser; static;
    function ReadNumber(out Value: Single): Boolean;
    function ReadFlag(out Value: Integer): Boolean;
    function Position: Integer;
    function Finished: Boolean;
  end;

type
  TSvgPathCommandType = (spMoveTo, spLineTo, spCurveTo, spClose);

  TSvgPathCommand = record
    Command: TSvgPathCommandType;
    P1, P2, P3: TPointF;
    class function Create(Command: TSvgPathCommandType; P1, P2, P3: TPointF): TSvgPathCommand; static;
  end;

  TSvgPath = class
  private
    FCommands: TList<TSvgPathCommand>;
    FCurrent: TPointF;
    FStart: TPointF;
    procedure AddCommand(Command: TSvgPathCommandType; const P1, P2, P3: TPointF);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure MoveTo(const P: TPointF);
    procedure LineTo(const P: TPointF);
    procedure CurveTo(const P1, P2, P3: TPointF);
    procedure ClosePath;
    procedure TransformTo(const Matrix: TSvgMatrix; Dest: TPathData);
    procedure AppendTo(Dest: TPathData; const Matrix: TSvgMatrix);
    property Commands: TList<TSvgPathCommand> read FCommands;
  end;

type
  TSvgPathParser = class
  private
    FText: string;
    FPos: Integer;
    FPath: TSvgPath;
    FCurrent: TPointF;
    FStart: TPointF;
    FLastCommand: Char;
    FLastCubicControl: TPointF;
    FLastQuadraticControl: TPointF;
    function IsCommandChar(C: Char): Boolean;
    function SkipSeparators: Boolean;
    function ReadNumber(out Value: Single): Boolean;
    function ReadFlag(out Value: Integer): Boolean;
    function ReadPoint(out P: TPointF): Boolean;
    function HasNumber: Boolean;
    procedure ParseMove(Relative: Boolean);
    procedure ParseLine(Relative: Boolean);
    procedure ParseHorizontal(Relative: Boolean);
    procedure ParseVertical(Relative: Boolean);
    procedure ParseCubic(Relative: Boolean);
    procedure ParseSmoothCubic(Relative: Boolean);
    procedure ParseQuadratic(Relative: Boolean);
    procedure ParseSmoothQuadratic(Relative: Boolean);
    procedure ParseArc(Relative: Boolean);
    procedure ParseClose;
    function ReflectCubicControl: TPointF;
    function ReflectQuadraticControl: TPointF;
    procedure AddArc(const P0, P1: TPointF; RX, RY, Rotation: Single; LargeArc, Sweep: Boolean);
  public
    constructor Create(APath: TSvgPath);
    procedure Parse(const S: string);
  end;

type
  TSvgFillRule = (sffNonZero, sffEvenOdd);

  TSvgPaint = record
    Enabled: Boolean;
    Color: TAlphaColor;
    GradientID: string;
  end;

  TSvgGradient = class
  public
    X1, Y1, X2, Y2: Single;
    Matrix: TSvgMatrix;
    Gradient: TGradient;

    constructor Create;
    destructor Destroy; override;
  end;

  TSvgStyle = record
    Fill: TSvgPaint;
    Stroke: TSvgPaint;
    StrokeWidth: Single;
    Opacity: Single;
    FillOpacity: Single;
    StrokeOpacity: Single;
    FillRule: TSvgFillRule;
    Visible: Boolean;
    class function Default: TSvgStyle; static;
  end;

  TSvgElement = class
  public
    Name: string;
    // Optional output label from an SVG title (LCD artwork uses x.y.z).
    OutputName: string;
    Path: TSvgPath;
    Matrix: TSvgMatrix;
    Style: TSvgStyle;
    ClipID: string;
    constructor Create;
    destructor Destroy; override;
  end;

  TSvgDocument = class
  private
    FElements: TObjectList<TSvgElement>;
    FClipPaths: TObjectDictionary<string, TSvgPath>;
    FGradients: TObjectDictionary<string, TSvgGradient>;
    FWidth: Single;
    FHeight: Single;
    FWidthLength: TSvgLength;
    FHeightLength: TSvgLength;
    FViewBox: TRectF;
    FHasViewBox: Boolean;
    procedure ParseNode(const Node: IXMLNode; const ParentMatrix: TSvgMatrix; const ParentStyle: TSvgStyle);
    procedure ParseShape(const Node: IXMLNode; const Matrix: TSvgMatrix; const Style: TSvgStyle);
    function ParseStyle(const Node: IXMLNode; const Parent: TSvgStyle): TSvgStyle;
    function ParseTransform(const S: string): TSvgMatrix;
    procedure ParsePath(Node: IXMLNode; Element: TSvgElement);
    procedure ParseRect(Node: IXMLNode; Element: TSvgElement);
    procedure ParseCircle(Node: IXMLNode; Element: TSvgElement);
    procedure ParseEllipse(Node: IXMLNode; Element: TSvgElement);
    procedure ParseLine(Node: IXMLNode; Element: TSvgElement);
    procedure ParsePoly(Node: IXMLNode; Element: TSvgElement; Closed: Boolean);
    procedure ParseClipPath(Node: IXMLNode; const Matrix: TSvgMatrix);
    procedure ParseLinearGradient(Node: IXMLNode);
    function Attr(const Node: IXMLNode; const Name: string; const Default: string = ''): string;
    function LengthAttr(const Node: IXMLNode; const Name: string; Reference: Single; Default: Single = 0): Single;
    function ParseFloat(const S: string; Default: Single = 0): Single;
    function ParseColor(const S: string; Default: TAlphaColor): TAlphaColor;
    function StyleAttr(const Node: IXMLNode; const Name: string; const Default: string = ''): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadFromString(const S: string);
    property Elements: TObjectList<TSvgElement> read FElements;
    property ClipPaths: TObjectDictionary<string, TSvgPath> read FClipPaths;
    property Gradients: TObjectDictionary<string, TSvgGradient> read FGradients;
    property Width: Single read FWidth;
    property Height: Single read FHeight;
    property WidthLength: TSvgLength read FWidthLength;
    property HeightLength: TSvgLength read FHeightLength;
    property ViewBox: TRectF read FViewBox;
    property HasViewBox: Boolean read FHasViewBox;
  end;

  TSvgControl = class(TControl)
  private
    FSVG: string;
    FDocument: TSvgDocument;
    FBitmap: TBitmap;
    FDocumentDirty: Boolean;
    FBitmapDirty: Boolean;
    FRenderScale: Single;
    procedure SetSVG(const Value: string);
    procedure SetRenderScale(const Value: Single);
    procedure EnsureDocument;
    procedure EnsureBitmap;
    procedure Rasterize;
    function GetContentMatrix: TSvgMatrix;
    procedure RenderElement(const Canvas: TCanvas; Element: TSvgElement; const ViewMatrix: TSvgMatrix);
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Reload;
    procedure RenderToBitmap(Bitmap: TBitmap; const Filter: TFunc<TSvgElement, Boolean>);
  published
    property SVG: string read FSVG write SetSVG;
    property RenderScale: Single read FRenderScale write SetRenderScale;
    property Align;
    property Anchors;
    property CanFocus;
    property Enabled;
    property HitTest;
    property Locked;
    property Opacity;
    property Position;
    property RotationAngle;
    property RotationCenter;
    property Scale;
    property Visible;
    property Width;
    property Height;
  end;

procedure Register;

implementation

uses
  System.StrUtils;

const
  SVG_EPS = 0.00001;
  SVG_KAPPA = 0.5522847498307936;

function InvariantFloat(const S: string; Default: Single = 0): Single;
begin
  var T := Trim(S);
  if T.IsEmpty then
    Exit(Default);
  T := T.Replace(',', '.');
  Result := StrToFloatDef(T, Default, TFormatSettings.Invariant);
end;

function AlphaColorWithOpacity(Color: TAlphaColor; Opacity: Single): TAlphaColor;
begin
  var A := Round(
    TAlphaColorRec(Color).A *
    EnsureRange(Opacity, 0, 1)
  );
  Result := (Color and $00FFFFFF) or (TAlphaColor(A) shl 24);
end;

function ContainsString(const Values: TArray<string>; const Value: string): Boolean;
begin
  for var S in Values do
    if SameText(S, Value) then
      Exit(True);
  Result := False;
end;

{ TSvgMatrix }

class function TSvgMatrix.Identity: TSvgMatrix;
begin
  Result.A := 1;
  Result.B := 0;
  Result.C := 0;
  Result.D := 1;
  Result.E := 0;
  Result.F := 0;
end;

class function TSvgMatrix.Translation(X, Y: Single): TSvgMatrix;
begin
  Result := Identity;
  Result.E := X;
  Result.F := Y;
end;

class function TSvgMatrix.Scaling(X, Y: Single): TSvgMatrix;
begin
  Result := Identity;
  Result.A := X;
  Result.D := Y;
end;

class function TSvgMatrix.Rotation(Radians: Single): TSvgMatrix;
begin
  var SinA := Sin(Radians);
  var CosA := Cos(Radians);
  Result.A := CosA;
  Result.B := SinA;
  Result.C := -SinA;
  Result.D := CosA;
  Result.E := 0;
  Result.F := 0;
end;

class function TSvgMatrix.SkewX(Radians: Single): TSvgMatrix;
begin
  Result := Identity;
  Result.C := Tan(Radians);
end;

class function TSvgMatrix.SkewY(Radians: Single): TSvgMatrix;
begin
  Result := Identity;
  Result.B := Tan(Radians);
end;

class function TSvgMatrix.FromSvg(A, B, C, D, E, F: Single): TSvgMatrix;
begin
  Result.A := A;
  Result.B := B;
  Result.C := C;
  Result.D := D;
  Result.E := E;
  Result.F := F;
end;

class operator TSvgMatrix.Multiply(const L, R: TSvgMatrix): TSvgMatrix;
begin
  Result.A := L.A * R.A + L.C * R.B;
  Result.B := L.B * R.A + L.D * R.B;
  Result.C := L.A * R.C + L.C * R.D;
  Result.D := L.B * R.C + L.D * R.D;
  Result.E := L.A * R.E + L.C * R.F + L.E;
  Result.F := L.B * R.E + L.D * R.F + L.F;
end;

function TSvgMatrix.TransformPoint(const P: TPointF): TPointF;
begin
  Result.X := A * P.X + C * P.Y + E;
  Result.Y := B * P.X + D * P.Y + F;
end;

{ TSvgLength }

class function TSvgLength.Parse(const S: string; Default: Single): TSvgLength;
begin
  Result.Value := Default;
  Result.units := sluNumber;
  var V := S.Trim;
  if V.IsEmpty then
    Exit;
  var P := 1;
  if CharInSet(V[P], ['+', '-']) then
    Inc(P);
  var HasDigits := False;
  while (P <= V.Length) and
    CharInSet(V[P], ['0'..'9']) do
  begin
    HasDigits := True;
    Inc(P);
  end;
  if (P <= V.Length) and (V[P] = '.') then
  begin
    Inc(P);
    while (P <= V.Length) and
      CharInSet(V[P], ['0'..'9']) do
    begin
      HasDigits := True;
      Inc(P);
    end;
  end;
  if HasDigits and
    (P <= V.Length) and
    CharInSet(V[P], ['e', 'E']) then
  begin
    var ExpPos := P;
    Inc(P);
    if (P <= V.Length) and
      CharInSet(V[P], ['+', '-']) then
      Inc(P);
    var ExpDigits := False;
    while (P <= V.Length) and
      CharInSet(V[P], ['0'..'9']) do
    begin
      ExpDigits := True;
      Inc(P);
    end;
    if not ExpDigits then
      P := ExpPos;
  end;
  if not HasDigits then
    Exit;
  Result.Value := InvariantFloat(V.Substring(0, P - 1), Default);
  var UnitName := V.Substring(P - 1).Trim.ToLower;
  if UnitName.IsEmpty then
    Result.units := sluNumber
  else if UnitName = 'px' then
    Result.units := sluPx
  else if UnitName = '%' then
    Result.units := sluPercent
  else if UnitName = 'em' then
    Result.units := sluEm
  else if UnitName = 'ex' then
    Result.units := sluEx
  else if UnitName = 'pt' then
    Result.units := sluPt
  else if UnitName = 'pc' then
    Result.units := sluPc
  else if UnitName = 'cm' then
    Result.units := sluCm
  else if UnitName = 'mm' then
    Result.units := sluMm
  else if UnitName = 'in' then
    Result.units := sluIn
  else
  begin
    Result.Value := Default;
    Result.units := sluNumber;
  end;
end;

function TSvgLength.Resolve(Reference, FontSize: Single): Single;
begin
  case units of
    sluNumber, sluPx:
      Result := Value;
    sluPercent:
      Result := Reference * Value / 100;
    sluEm:
      Result := FontSize * Value;
    sluEx:
      Result := FontSize * 0.5 * Value;
    sluPt:
      Result := Value * 96 / 72;
    sluPc:
      Result := Value * 96 / 6;
    sluCm:
      Result := Value * 96 / 2.54;
    sluMm:
      Result := Value * 96 / 25.4;
    sluIn:
      Result := Value * 96;
  else
    Result := Value;
  end;
end;

{ TSvgNumberParser }

class function TSvgNumberParser.Create(const S: string): TSvgNumberParser;
begin
  Result.FText := S;
  Result.FPos := 1;
end;

procedure TSvgNumberParser.SkipSeparators;
begin
  while FPos <= FText.Length do
  begin
    if CharInSet(FText[FPos], [' ', #9, #10, #13, ',']) then
      Inc(FPos)
    else
      Break;
  end;
end;

function TSvgNumberParser.ReadNumber(out Value: Single): Boolean;
begin
  Result := False;
  SkipSeparators;
  if FPos > FText.Length then
    Exit;
  var Start := FPos;
  if CharInSet(FText[FPos], ['+', '-']) then
    Inc(FPos);
  var HasDigits := False;
  while (FPos <= FText.Length) and
    CharInSet(FText[FPos], ['0'..'9']) do
  begin
    HasDigits := True;
    Inc(FPos);
  end;
  if (FPos <= FText.Length) and
    (FText[FPos] = '.') then
  begin
    Inc(FPos);
    while (FPos <= FText.Length) and
      CharInSet(FText[FPos], ['0'..'9']) do
    begin
      HasDigits := True;
      Inc(FPos);
    end;
  end;
  if HasDigits and
    (FPos <= FText.Length) and
    CharInSet(FText[FPos], ['e', 'E']) then
  begin
    var ExpPos := FPos;
    Inc(FPos);
    if (FPos <= FText.Length) and
      CharInSet(FText[FPos], ['+', '-']) then
      Inc(FPos);
    var ExpDigits := False;
    while (FPos <= FText.Length) and
      CharInSet(FText[FPos], ['0'..'9']) do
    begin
      ExpDigits := True;
      Inc(FPos);
    end;
    if not ExpDigits then
      FPos := ExpPos;
  end;
  if not HasDigits then
  begin
    FPos := Start;
    Exit;
  end;
  Value := InvariantFloat(
    FText.Substring(Start - 1, FPos - Start)
  );
  Result := True;
end;

function TSvgNumberParser.ReadFlag(out Value: Integer): Boolean;
begin
  SkipSeparators;
  Result := False;
  if FPos > FText.Length then
    Exit;
  if FText[FPos] = '0' then
  begin
    Value := 0;
    Inc(FPos);
    Exit(True);
  end;
  if FText[FPos] = '1' then
  begin
    Value := 1;
    Inc(FPos);
    Exit(True);
  end;
end;

function TSvgNumberParser.Position: Integer;
begin
  Result := FPos;
end;

function TSvgNumberParser.Finished: Boolean;
begin
  SkipSeparators;
  Result := FPos > FText.Length;
end;

{ TSvgPathCommand }

class function TSvgPathCommand.Create(Command: TSvgPathCommandType; P1, P2, P3: TPointF): TSvgPathCommand;
begin
  Result.Command := Command;
  Result.P1 := P1;
  Result.P2 := P2;
  Result.P3 := P3;
end;

{ TSvgPath }

constructor TSvgPath.Create;
begin
  inherited;
  FCommands := TList<TSvgPathCommand>.Create;
end;

destructor TSvgPath.Destroy;
begin
  FCommands.Free;
  inherited;
end;

procedure TSvgPath.Clear;
begin
  FCommands.Clear;
  FCurrent := PointF(0, 0);
  FStart := PointF(0, 0);
end;

procedure TSvgPath.AddCommand(Command: TSvgPathCommandType; const P1, P2, P3: TPointF);
begin
  FCommands.Add(
    TSvgPathCommand.Create(Command, P1, P2, P3)
  );
end;

procedure TSvgPath.MoveTo(const P: TPointF);
begin
  AddCommand(
    spMoveTo,
    P,
    PointF(0, 0),
    PointF(0, 0)
  );
  FCurrent := P;
  FStart := P;
end;

procedure TSvgPath.LineTo(const P: TPointF);
begin
  AddCommand(
    spLineTo,
    P,
    PointF(0, 0),
    PointF(0, 0)
  );
  FCurrent := P;
end;

procedure TSvgPath.CurveTo(const P1, P2, P3: TPointF);
begin
  AddCommand(spCurveTo, P1, P2, P3);
  FCurrent := P3;
end;

procedure TSvgPath.ClosePath;
begin
  AddCommand(
    spClose,
    PointF(0, 0),
    PointF(0, 0),
    PointF(0, 0)
  );
  FCurrent := FStart;
end;

procedure TSvgPath.AppendTo(Dest: TPathData; const Matrix: TSvgMatrix);
begin
  for var Command in FCommands do
    case Command.Command of
      spMoveTo:
        Dest.MoveTo(
          Matrix.TransformPoint(Command.P1)
        );
      spLineTo:
        Dest.LineTo(
          Matrix.TransformPoint(Command.P1)
        );
      spCurveTo:
        Dest.CurveTo(
          Matrix.TransformPoint(Command.P1),
          Matrix.TransformPoint(Command.P2),
          Matrix.TransformPoint(Command.P3)
        );
      spClose:
        Dest.ClosePath;
    end;
end;

procedure TSvgPath.TransformTo(const Matrix: TSvgMatrix; Dest: TPathData);
begin
  Dest.Clear;
  AppendTo(Dest, Matrix);
end;

{ TSvgPathParser }

constructor TSvgPathParser.Create(APath: TSvgPath);
begin
  inherited Create;
  FPath := APath;
end;

function TSvgPathParser.IsCommandChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['M', 'm', 'L', 'l', 'H', 'h', 'V', 'v', 'C', 'c', 'S', 's', 'Q', 'q', 'T', 't', 'A', 'a', 'Z', 'z']);
end;

function TSvgPathParser.SkipSeparators: Boolean;
begin
  while FPos <= FText.Length do
  begin
    if CharInSet(FText[FPos], [' ', #9, #10, #13, ',']) then
      Inc(FPos)
    else
      Break;
  end;
  Result := FPos <= FText.Length;
end;

function TSvgPathParser.HasNumber: Boolean;
begin
  SkipSeparators;
  Result := (FPos <= FText.Length) and not IsCommandChar(FText[FPos]);
end;

function TSvgPathParser.ReadNumber(out Value: Single): Boolean;
begin
  var Parser := TSvgNumberParser.Create(
    FText.Substring(FPos - 1)
  );
  Result := Parser.ReadNumber(Value);
  if Result then
    FPos := FPos + Parser.Position - 1;
end;

function TSvgPathParser.ReadFlag(out Value: Integer): Boolean;
begin
  var Parser := TSvgNumberParser.Create(
    FText.Substring(FPos - 1)
  );
  Result := Parser.ReadFlag(Value);
  if Result then
    FPos := FPos + Parser.Position - 1;
end;

function TSvgPathParser.ReadPoint(out P: TPointF): Boolean;
begin
  Result := ReadNumber(P.X) and ReadNumber(P.Y);
end;

function TSvgPathParser.ReflectCubicControl: TPointF;
begin
  if CharInSet(FLastCommand, ['C', 'c', 'S', 's']) then
  begin
    Result := PointF(2 * FCurrent.X - FLastCubicControl.X, 2 * FCurrent.Y - FLastCubicControl.Y);
  end
  else
    Result := FCurrent;
end;

function TSvgPathParser.ReflectQuadraticControl: TPointF;
begin
  if CharInSet(FLastCommand, ['Q', 'q', 'T', 't']) then
  begin
    Result := PointF(2 * FCurrent.X - FLastQuadraticControl.X, 2 * FCurrent.Y - FLastQuadraticControl.Y);
  end
  else
    Result := FCurrent;
end;

procedure TSvgPathParser.ParseMove(Relative: Boolean);
begin
  var First := True;
  while HasNumber do
  begin
    var P: TPointF;
    if not ReadPoint(P) then
      Break;
    if Relative then
      P := P + FCurrent;
    if First then
    begin
      FPath.MoveTo(P);
      FStart := P;
      First := False;
      if Relative then
        FLastCommand := 'm'
      else
        FLastCommand := 'M';
    end
    else
    begin
      FPath.LineTo(P);
      if Relative then
        FLastCommand := 'l'
      else
        FLastCommand := 'L';
    end;
    FCurrent := P;
  end;
end;

procedure TSvgPathParser.ParseLine(Relative: Boolean);
begin
  while HasNumber do
  begin
    var P: TPointF;
    if not ReadPoint(P) then
      Break;
    if Relative then
      P := P + FCurrent;
    FPath.LineTo(P);
    FCurrent := P;
    if Relative then
      FLastCommand := 'l'
    else
      FLastCommand := 'L';
  end;
end;

procedure TSvgPathParser.ParseHorizontal(Relative: Boolean);
begin
  while HasNumber do
  begin
    var X: Single;
    if not ReadNumber(X) then
      Break;
    if Relative then
      X := X + FCurrent.X;
    FCurrent.X := X;
    FPath.LineTo(FCurrent);
    if Relative then
      FLastCommand := 'h'
    else
      FLastCommand := 'H';
  end;
end;

procedure TSvgPathParser.ParseVertical(Relative: Boolean);
begin
  while HasNumber do
  begin
    var Y: Single;
    if not ReadNumber(Y) then
      Break;
    if Relative then
      Y := Y + FCurrent.Y;
    FCurrent.Y := Y;
    FPath.LineTo(FCurrent);
    if Relative then
      FLastCommand := 'v'
    else
      FLastCommand := 'V';
  end;
end;

procedure TSvgPathParser.ParseCubic(Relative: Boolean);
begin
  while HasNumber do
  begin
    var P1, P2, P3: TPointF;
    if not ReadPoint(P1) then
      Break;
    if not ReadPoint(P2) then
      Break;
    if not ReadPoint(P3) then
      Break;
    if Relative then
    begin
      P1 := P1 + FCurrent;
      P2 := P2 + FCurrent;
      P3 := P3 + FCurrent;
    end;
    FPath.CurveTo(P1, P2, P3);
    FCurrent := P3;
    FLastCubicControl := P2;
    if Relative then
      FLastCommand := 'c'
    else
      FLastCommand := 'C';
  end;
end;

procedure TSvgPathParser.ParseSmoothCubic(Relative: Boolean);
begin
  while HasNumber do
  begin
    var P1 := ReflectCubicControl;
    var P2, P3: TPointF;
    if not ReadPoint(P2) then
      Break;
    if not ReadPoint(P3) then
      Break;
    if Relative then
    begin
      P2 := P2 + FCurrent;
      P3 := P3 + FCurrent;
    end;
    FPath.CurveTo(P1, P2, P3);
    FCurrent := P3;
    FLastCubicControl := P2;
    if Relative then
      FLastCommand := 's'
    else
      FLastCommand := 'S';
  end;
end;

procedure TSvgPathParser.ParseQuadratic(Relative: Boolean);
begin
  while HasNumber do
  begin
    var Q, P: TPointF;
    if not ReadPoint(Q) then
      Break;
    if not ReadPoint(P) then
      Break;
    if Relative then
    begin
      Q := Q + FCurrent;
      P := P + FCurrent;
    end;
    var C1 := PointF(
      FCurrent.X +
      (2 / 3) * (Q.X - FCurrent.X),
      FCurrent.Y +
      (2 / 3) * (Q.Y - FCurrent.Y)
    );
    var C2 := PointF(
      P.X +
      (2 / 3) * (Q.X - P.X),
      P.Y +
      (2 / 3) * (Q.Y - P.Y)
    );
    FPath.CurveTo(C1, C2, P);
    FLastQuadraticControl := Q;
    FCurrent := P;
    if Relative then
      FLastCommand := 'q'
    else
      FLastCommand := 'Q';
  end;
end;

procedure TSvgPathParser.ParseSmoothQuadratic(Relative: Boolean);
begin
  while HasNumber do
  begin
    var Q := ReflectQuadraticControl;
    var P: TPointF;
    if not ReadPoint(P) then
      Break;
    if Relative then
      P := P + FCurrent;
    var C1 := PointF(
      FCurrent.X +
      (2 / 3) * (Q.X - FCurrent.X),
      FCurrent.Y +
      (2 / 3) * (Q.Y - FCurrent.Y)
    );
    var C2 := PointF(
      P.X +
      (2 / 3) * (Q.X - P.X),
      P.Y +
      (2 / 3) * (Q.Y - P.Y)
    );
    FPath.CurveTo(C1, C2, P);
    FLastQuadraticControl := Q;
    FCurrent := P;
    if Relative then
      FLastCommand := 't'
    else
      FLastCommand := 'T';
  end;
end;

procedure TSvgPathParser.AddArc(const P0, P1: TPointF; RX, RY, Rotation: Single; LargeArc, Sweep: Boolean);
begin
  RX := Abs(RX);
  RY := Abs(RY);
  if (RX < SVG_EPS) or
    (RY < SVG_EPS) then
  begin
    FPath.LineTo(P1);
    FCurrent := P1;
    Exit;
  end;
  if SameValue(P0.X, P1.X, SVG_EPS) and
    SameValue(P0.Y, P1.Y, SVG_EPS) then
    Exit;
  var Phi := DegToRad(Rotation);
  var CosPhi := Cos(Phi);
  var SinPhi := Sin(Phi);
  var DX := (P0.X - P1.X) / 2;
  var DY := (P0.Y - P1.Y) / 2;
  var X1p := CosPhi * DX + SinPhi * DY;
  var Y1p := -SinPhi * DX + CosPhi * DY;
  var Lambda := Sqr(X1p / RX) + Sqr(Y1p / RY);
  if Lambda > 1 then
  begin
    var Scale := Sqrt(Lambda);
    RX := RX * Scale;
    RY := RY * Scale;
  end;
  var RX2 := Sqr(RX);
  var RY2 := Sqr(RY);
  var X1p2 := Sqr(X1p);
  var Y1p2 := Sqr(Y1p);
  var Denominator := RX2 * Y1p2 + RY2 * X1p2;
  var Numerator := RX2 * RY2 - Denominator;
  if Numerator < 0 then
    Numerator := 0;
  var Coeff := Sqrt(Numerator / Max(Denominator, SVG_EPS));
  if LargeArc = Sweep then
    Coeff := -Coeff;
  var Cxp := Coeff * (RX * Y1p / RY);
  var Cyp := Coeff * (-RY * X1p / RX);
  var CX := CosPhi * Cxp - SinPhi * Cyp + (P0.X + P1.X) / 2;
  var CY := SinPhi * Cxp + CosPhi * Cyp + (P0.Y + P1.Y) / 2;
  var Ux := (X1p - Cxp) / RX;
  var Uy := (Y1p - Cyp) / RY;
  var Vx := (-X1p - Cxp) / RX;
  var Vy := (-Y1p - Cyp) / RY;
  var Theta1 := ArcTan2(Uy, Ux);
  var Delta := ArcTan2(Ux * Vy - Uy * Vx, Ux * Vx + Uy * Vy);
  if (not Sweep) and
    (Delta > 0) then
    Delta := Delta - 2 * Pi
  else if Sweep and
    (Delta < 0) then
    Delta := Delta + 2 * Pi;
  var Segments := Ceil(Abs(Delta) / (Pi / 2));
  if Segments <= 0 then
  begin
    FCurrent := P1;
    Exit;
  end;
  var DeltaSegment := Delta / Segments;
  for var I := 0 to Segments - 1 do
  begin
    var T1 := Theta1 + I * DeltaSegment;
    var T2 := T1 + DeltaSegment;
    var Alpha := (4 / 3) * Tan((T2 - T1) / 4);
    var Cos1 := Cos(T1);
    var Sin1 := Sin(T1);
    var Cos2 := Cos(T2);
    var Sin2 := Sin(T2);
    var PStart := PointF(CX + CosPhi * RX * Cos1 - SinPhi * RY * Sin1, CY + SinPhi * RX * Cos1 + CosPhi * RY * Sin1);
    var PEnd := PointF(CX + CosPhi * RX * Cos2 - SinPhi * RY * Sin2, CY + SinPhi * RX * Cos2 + CosPhi * RY * Sin2);
    var C1 := PointF(
      PStart.X +
      Alpha *
      (-CosPhi * RX * Sin1 - SinPhi * RY * Cos1),
      PStart.Y +
      Alpha *
      (-SinPhi * RX * Sin1 + CosPhi * RY * Cos1)
    );
    var C2 := PointF(
      PEnd.X -
      Alpha *
      (-CosPhi * RX * Sin2 - SinPhi * RY * Cos2),
      PEnd.Y -
      Alpha *
      (-SinPhi * RX * Sin2 + CosPhi * RY * Cos2)
    );
    FPath.CurveTo(C1, C2, PEnd);
  end;
  FCurrent := P1;
end;

procedure TSvgPathParser.ParseArc(Relative: Boolean);
begin
  while HasNumber do
  begin
    var RX, RY, Rotation: Single;
    var LargeArc, Sweep: Integer;
    var P: TPointF;
    if not ReadNumber(RX) then
      Break;
    if not ReadNumber(RY) then
      Break;
    if not ReadNumber(Rotation) then
      Break;
    if not ReadFlag(LargeArc) then
      Break;
    if not ReadFlag(Sweep) then
      Break;
    if not ReadPoint(P) then
      Break;
    if Relative then
      P := P + FCurrent;
    AddArc(FCurrent, P, RX, RY, Rotation, LargeArc <> 0, Sweep <> 0);
    if Relative then
      FLastCommand := 'a'
    else
      FLastCommand := 'A';
  end;
end;

procedure TSvgPathParser.ParseClose;
begin
  FPath.ClosePath;
  FCurrent := FStart;
  FLastCommand := 'Z';
end;

procedure TSvgPathParser.Parse(const S: string);
begin
  FPath.Clear;
  FText := S;
  FPos := 1;
  FCurrent := PointF(0, 0);
  FStart := PointF(0, 0);
  FLastCommand := #0;
  FLastCubicControl := FCurrent;
  FLastQuadraticControl := FCurrent;
  while FPos <= FText.Length do
  begin
    SkipSeparators;
    if FPos > FText.Length then
      Break;
    var Command := FText[FPos];
    if IsCommandChar(Command) then
    begin
      Inc(FPos);
    end
    else if FLastCommand = #0 then
    begin
      Inc(FPos);
      Continue;
    end
    else if CharInSet(FLastCommand, ['Z', 'z']) then
    begin
      Inc(FPos);
      Continue;
    end
    else
      Command := FLastCommand;
    case Command of
      'M':
        ParseMove(False);
      'm':
        ParseMove(True);
      'L':
        ParseLine(False);
      'l':
        ParseLine(True);
      'H':
        ParseHorizontal(False);
      'h':
        ParseHorizontal(True);
      'V':
        ParseVertical(False);
      'v':
        ParseVertical(True);
      'C':
        ParseCubic(False);
      'c':
        ParseCubic(True);
      'S':
        ParseSmoothCubic(False);
      's':
        ParseSmoothCubic(True);
      'Q':
        ParseQuadratic(False);
      'q':
        ParseQuadratic(True);
      'T':
        ParseSmoothQuadratic(False);
      't':
        ParseSmoothQuadratic(True);
      'A':
        ParseArc(False);
      'a':
        ParseArc(True);
      'Z', 'z':
        ParseClose;
    end;
  end;
end;

{ TSvgStyle }

constructor TSvgGradient.Create;
begin
  inherited;
  X1 := 0;
  Y1 := 0;
  X2 := 1;
  Y2 := 0;
  Matrix := TSvgMatrix.Identity;
  Gradient := TGradient.Create;
  Gradient.Points.Clear;
end;

function GradientIDFromPaint(const Value: string): string;
begin
  var Paint := Value.Trim;
  if not Paint.StartsWith('url(') or not Paint.EndsWith(')') then
    Exit('');
  Result := Paint.Substring(4, Paint.Length - 5).Trim;
  if Result.StartsWith('#') then
    Result := Result.Substring(1)
  else
    Result := '';
end;

destructor TSvgGradient.Destroy;
begin
  Gradient.Free;
  inherited;
end;

class function TSvgStyle.Default: TSvgStyle;
begin
  Result.Visible := True;
  Result.Opacity := 1;
  Result.FillOpacity := 1;
  Result.StrokeOpacity := 1;
  Result.StrokeWidth := 1;
  Result.FillRule := sffNonZero;
  Result.Fill.Enabled := True;
  Result.Fill.Color := TAlphaColorRec.Black;
  Result.Fill.GradientID := '';
  Result.Stroke.Enabled := False;
  Result.Stroke.Color := TAlphaColorRec.Black;
end;

{ TSvgElement }

constructor TSvgElement.Create;
begin
  inherited;
  Path := TSvgPath.Create;
  Matrix := TSvgMatrix.Identity;
  Style := TSvgStyle.Default;
end;

destructor TSvgElement.Destroy;
begin
  Path.Free;
  inherited;
end;

{ TSvgDocument }

constructor TSvgDocument.Create;
begin
  inherited;
  FElements := TObjectList<TSvgElement>.Create(True);
  FClipPaths := TObjectDictionary<string, TSvgPath>.Create([doOwnsValues]);
  FGradients := TObjectDictionary<string, TSvgGradient>.Create([doOwnsValues]);
end;

destructor TSvgDocument.Destroy;
begin
  FClipPaths.Free;
  FGradients.Free;
  FElements.Free;
  inherited;
end;

procedure TSvgDocument.Clear;
begin
  FElements.Clear;
  FClipPaths.Clear;
  FGradients.Clear;
  FWidth := 0;
  FHeight := 0;
  FWidthLength.Value := 0;
  FWidthLength.units := sluNumber;
  FHeightLength.Value := 0;
  FHeightLength.units := sluNumber;
  FViewBox := TRectF.Empty;
  FHasViewBox := False;
end;

function TSvgDocument.ParseFloat(const S: string; Default: Single): Single;
begin
  var V := S.Trim.Replace(',', '.');
  if V.IsEmpty then
    Exit(Default);
  Result := InvariantFloat(V, Default);
end;

function TSvgDocument.Attr(const Node: IXMLNode; const Name: string; const Default: string): string;
begin
  if Node.HasAttribute(Name) then
    Result := Node.Attributes[Name]
  else
    Result := Default;
end;

function TSvgDocument.StyleAttr(const Node: IXMLNode; const Name: string; const Default: string): string;
begin
  Result := Attr(Node, Name, Default);
  var Style := Attr(Node, 'style');
  for var Declaration in Style.Split([';']) do
  begin
    var Separator := Declaration.IndexOf(':');
    if (Separator >= 0) and SameText(Declaration.Substring(0, Separator).Trim, Name) then
      Exit(Declaration.Substring(Separator + 1).Trim);
  end;
end;

function TSvgDocument.LengthAttr(const Node: IXMLNode; const Name: string; Reference: Single; Default: Single): Single;
begin
  var S := Attr(Node, Name);
  if S.IsEmpty then
    Exit(Default);
  Result := TSvgLength.Parse(S, Default).Resolve(Reference, 16);
end;

function TSvgDocument.ParseColor(const S: string; Default: TAlphaColor): TAlphaColor;
begin
  var V := S.Trim.ToLower;
  if V.IsEmpty then
    Exit(Default);
  if V = 'none' then
    Exit(0);
  if V.StartsWith('#') then
  begin
    var Hex := V.Substring(1);
    try
      var R, G, B, A: Integer;
      if Hex.Length = 3 then
      begin
        R := StrToInt(
          '$' + Hex.Substring(0, 1)
        ) * 17;
        G := StrToInt(
          '$' + Hex.Substring(1, 1)
        ) * 17;
        B := StrToInt(
          '$' + Hex.Substring(2, 1)
        ) * 17;
        A := 255;
      end
      else if Hex.Length = 6 then
      begin
        R := StrToInt(
          '$' + Hex.Substring(0, 2)
        );
        G := StrToInt(
          '$' + Hex.Substring(2, 2)
        );
        B := StrToInt(
          '$' + Hex.Substring(4, 2)
        );
        A := 255;
      end
      else if Hex.Length = 8 then
      begin
        R := StrToInt(
          '$' + Hex.Substring(0, 2)
        );
        G := StrToInt(
          '$' + Hex.Substring(2, 2)
        );
        B := StrToInt(
          '$' + Hex.Substring(4, 2)
        );
        A := StrToInt(
          '$' + Hex.Substring(6, 2)
        );
      end
      else
        Exit(Default);
      Exit(
        TAlphaColor(A) shl 24 or
        TAlphaColor(R) shl 16 or
        TAlphaColor(G) shl 8 or
        TAlphaColor(B)
      );
    except
      Exit(Default);
    end;
  end;
  if V = 'black' then
    Exit(TAlphaColorRec.Black);
  if V = 'white' then
    Exit(TAlphaColorRec.White);
  if V = 'red' then
    Exit(TAlphaColorRec.Red);
  if V = 'green' then
    Exit(TAlphaColorRec.Green);
  if V = 'blue' then
    Exit(TAlphaColorRec.Blue);
  if V = 'yellow' then
    Exit(TAlphaColorRec.Yellow);
  if V = 'gray' then
    Exit(TAlphaColorRec.Gray);
  Result := Default;
end;

function TSvgDocument.ParseStyle(const Node: IXMLNode; const Parent: TSvgStyle): TSvgStyle;
begin
  Result := Parent;
  var S := Attr(Node, 'display');
  if SameText(S.Trim, 'none') then
    Result.Visible := False;
  S := Attr(Node, 'visibility');
  if SameText(S.Trim, 'hidden') then
    Result.Visible := False;
  S := Attr(Node, 'fill');
  if not S.IsEmpty then
  begin
    Result.Fill.Enabled := not SameText(S.Trim, 'none');
    Result.Fill.GradientID := GradientIDFromPaint(S);
    if Result.Fill.Enabled and Result.Fill.GradientID.IsEmpty then
      Result.Fill.Color := ParseColor(S, Result.Fill.Color);
  end;
  S := Attr(Node, 'stroke');
  if not S.IsEmpty then
  begin
    Result.Stroke.Enabled := not SameText(S.Trim, 'none');
    if Result.Stroke.Enabled then
      Result.Stroke.Color := ParseColor(S, Result.Stroke.Color);
  end;
  S := Attr(Node, 'stroke-width');
  if not S.IsEmpty then
    Result.StrokeWidth := TSvgLength.Parse(S, Result.StrokeWidth).Resolve(FWidth, 16);
  S := Attr(Node, 'opacity');
  if not S.IsEmpty then
    Result.Opacity := EnsureRange(ParseFloat(S, 1), 0, 1);
  S := Attr(Node, 'fill-opacity');
  if not S.IsEmpty then
    Result.FillOpacity := EnsureRange(ParseFloat(S, 1), 0, 1);
  S := Attr(Node, 'stroke-opacity');
  if not S.IsEmpty then
    Result.StrokeOpacity := EnsureRange(ParseFloat(S, 1), 0, 1);
  S := Attr(Node, 'fill-rule');
  if SameText(S.Trim, 'evenodd') then
    Result.FillRule := sffEvenOdd
  else if SameText(S.Trim, 'nonzero') then
    Result.FillRule := sffNonZero;
  S := Attr(Node, 'style');
  if not S.IsEmpty then
  begin
    for var Declaration in S.Split([';']) do
    begin
      var P := Declaration.IndexOf(':');
      if P < 0 then
        Continue;
      var Name := Declaration.Substring(0, P).Trim.ToLower;
      var Value := Declaration.Substring(P + 1).Trim;
      if Name = 'fill' then
      begin
        Result.Fill.Enabled := not SameText(Value, 'none');
        Result.Fill.GradientID := GradientIDFromPaint(Value);
        if Result.Fill.Enabled and Result.Fill.GradientID.IsEmpty then
          Result.Fill.Color := ParseColor(Value, Result.Fill.Color);
      end
      else if Name = 'stroke' then
      begin
        Result.Stroke.Enabled := not SameText(Value, 'none');
        if Result.Stroke.Enabled then
          Result.Stroke.Color := ParseColor(Value, Result.Stroke.Color);
      end
      else if Name = 'stroke-width' then
      begin
        Result.StrokeWidth := TSvgLength.Parse(Value, Result.StrokeWidth).Resolve(FWidth, 16);
      end
      else if Name = 'opacity' then
      begin
        Result.Opacity := EnsureRange(ParseFloat(Value, 1), 0, 1);
      end
      else if Name = 'fill-opacity' then
      begin
        Result.FillOpacity := EnsureRange(ParseFloat(Value, 1), 0, 1);
      end
      else if Name = 'stroke-opacity' then
      begin
        Result.StrokeOpacity := EnsureRange(ParseFloat(Value, 1), 0, 1);
      end
      else if Name = 'fill-rule' then
      begin
        if SameText(Value, 'evenodd') then
          Result.FillRule := sffEvenOdd
        else
          Result.FillRule := sffNonZero;
      end
      else if Name = 'display' then
      begin
        Result.Visible := not SameText(Value, 'none');
      end
      else if Name = 'visibility' then
      begin
        Result.Visible := not SameText(Value, 'hidden');
      end;
    end;
  end;
end;

function TSvgDocument.ParseTransform(const S: string): TSvgMatrix;
begin
  Result := TSvgMatrix.Identity;
  var P := 1;
  while P <= S.Length do
  begin
    while (P <= S.Length) and
    CharInSet(S[P], [' ', ',', #9, #10, #13]) do
      Inc(P);
    if P > S.Length then
      Break;
    var Start := P;
    while (P <= S.Length) and
      CharInSet(S[P], ['A'..'Z', 'a'..'z']) do
      Inc(P);
    var Name := S.Substring(Start - 1, P - Start).Trim.ToLower;
    while (P <= S.Length) and
      (S[P] <> '(') do
      Inc(P);
    if P > S.Length then
      Break;
    Inc(P);
    var ArgStart := P;
    var Depth := 1;
    while (P <= S.Length) and
      (Depth > 0) do
    begin
      if S[P] = '(' then
        Inc(Depth)
      else if S[P] = ')' then
        Dec(Depth);
      if Depth > 0 then
        Inc(P);
    end;
    var Args := S.Substring(ArgStart - 1, P - ArgStart);
    if (P <= S.Length) and
      (S[P] = ')') then
      Inc(P);
    var Parser := TSvgNumberParser.Create(Args);
    var Values: TArray<Single>;
    var Value: Single;
    while Parser.ReadNumber(Value) do
    begin
      Values := Values + [Value];
    end;
    var M := TSvgMatrix.Identity;
    if Name = 'translate' then
    begin
      if Length(Values) >= 1 then
      begin
        var X := Values[0];
        var Y := 0.0;
        if Length(Values) >= 2 then
          Y := Values[1];
        M := TSvgMatrix.Translation(X, Y);
      end;
    end
    else if Name = 'scale' then
    begin
      if Length(Values) >= 1 then
      begin
        var X := Values[0];
        var Y := X;
        if Length(Values) >= 2 then
          Y := Values[1];
        M := TSvgMatrix.Scaling(X, Y);
      end;
    end
    else if Name = 'rotate' then
    begin
      if Length(Values) >= 1 then
      begin
        var A := DegToRad(Values[0]);
        if Length(Values) >= 3 then
        begin
          var X := Values[1];
          var Y := Values[2];
          M :=
            TSvgMatrix.Translation(X, Y) *
            TSvgMatrix.Rotation(A) *
            TSvgMatrix.Translation(-X, -Y);
        end
        else
          M := TSvgMatrix.Rotation(A);
      end;
    end
    else if Name = 'skewx' then
    begin
      if Length(Values) >= 1 then
        M := TSvgMatrix.SkewX(DegToRad(Values[0]));
    end
    else if Name = 'skewy' then
    begin
      if Length(Values) >= 1 then
        M := TSvgMatrix.SkewY(DegToRad(Values[0]));
    end
    else if Name = 'matrix' then
    begin
      if Length(Values) >= 6 then
        M := TSvgMatrix.FromSvg(Values[0], Values[1], Values[2], Values[3], Values[4], Values[5]);
    end;
    Result := Result * M;
  end;
end;

procedure TSvgDocument.ParsePath(Node: IXMLNode; Element: TSvgElement);
begin
  var Parser := TSvgPathParser.Create(Element.Path);
  try
    Parser.Parse(
      Attr(Node, 'd')
    );
  finally
    Parser.Free;
  end;
end;

procedure TSvgDocument.ParseRect(Node: IXMLNode; Element: TSvgElement);
begin
  var X := LengthAttr(Node, 'x', FWidth);
  var Y := LengthAttr(Node, 'y', FHeight);
  var W := LengthAttr(Node, 'width', FWidth);
  var H := LengthAttr(Node, 'height', FHeight);
  if (W <= 0) or (H <= 0) then
    Exit;
  var RX := LengthAttr(Node, 'rx', W);
  var RY := LengthAttr(Node, 'ry', H);
  if RX <= 0 then
    RX := RY;
  if RY <= 0 then
    RY := RX;
  RX := Min(RX, W / 2);
  RY := Min(RY, H / 2);
  if (RX <= 0) or
    (RY <= 0) then
  begin
    Element.Path.MoveTo(
      PointF(X, Y)
    );
    Element.Path.LineTo(
      PointF(X + W, Y)
    );
    Element.Path.LineTo(
      PointF(X + W, Y + H)
    );
    Element.Path.LineTo(
      PointF(X, Y + H)
    );
    Element.Path.ClosePath;
    Exit;
  end;
  var K := SVG_KAPPA;
  Element.Path.MoveTo(
    PointF(X + RX, Y)
  );
  Element.Path.LineTo(
    PointF(X + W - RX, Y)
  );
  Element.Path.CurveTo(
    PointF(X + W - RX + K * RX, Y),
    PointF(X + W, Y + RY - K * RY),
    PointF(X + W, Y + RY)
  );
  Element.Path.LineTo(
    PointF(X + W, Y + H - RY)
  );
  Element.Path.CurveTo(
    PointF(X + W, Y + H - RY + K * RY),
    PointF(X + W - RX + K * RX, Y + H),
    PointF(X + W - RX, Y + H)
  );
  Element.Path.LineTo(
    PointF(X + RX, Y + H)
  );
  Element.Path.CurveTo(
    PointF(X + RX - K * RX, Y + H),
    PointF(X, Y + H - RY + K * RY),
    PointF(X, Y + H - RY)
  );
  Element.Path.LineTo(
    PointF(X, Y + RY)
  );
  Element.Path.CurveTo(
    PointF(X, Y + RY - K * RY),
    PointF(X + RX - K * RX, Y),
    PointF(X + RX, Y)
  );
  Element.Path.ClosePath;
end;

procedure TSvgDocument.ParseCircle(Node: IXMLNode; Element: TSvgElement);
begin
  var CX := LengthAttr(Node, 'cx', FWidth);
  var CY := LengthAttr(Node, 'cy', FHeight);
  var R := LengthAttr(Node, 'r', Min(FWidth, FHeight));
  if R <= 0 then
    Exit;
  var K := SVG_KAPPA;
  Element.Path.MoveTo(
    PointF(CX + R, CY)
  );
  Element.Path.CurveTo(
    PointF(CX + R, CY + K * R),
    PointF(CX + K * R, CY + R),
    PointF(CX, CY + R)
  );
  Element.Path.CurveTo(
    PointF(CX - K * R, CY + R),
    PointF(CX - R, CY + K * R),
    PointF(CX - R, CY)
  );
  Element.Path.CurveTo(
    PointF(CX - R, CY - K * R),
    PointF(CX - K * R, CY - R),
    PointF(CX, CY - R)
  );
  Element.Path.CurveTo(
    PointF(CX + K * R, CY - R),
    PointF(CX + R, CY - K * R),
    PointF(CX + R, CY)
  );
  Element.Path.ClosePath;
end;

procedure TSvgDocument.ParseEllipse(Node: IXMLNode; Element: TSvgElement);
begin
  var CX := LengthAttr(Node, 'cx', FWidth);
  var CY := LengthAttr(Node, 'cy', FHeight);
  var RX := LengthAttr(Node, 'rx', FWidth);
  var RY := LengthAttr(Node, 'ry', FHeight);
  if (RX <= 0) or (RY <= 0) then
    Exit;
  var K := SVG_KAPPA;
  Element.Path.MoveTo(
    PointF(CX + RX, CY)
  );
  Element.Path.CurveTo(
    PointF(CX + RX, CY + K * RY),
    PointF(CX + K * RX, CY + RY),
    PointF(CX, CY + RY)
  );
  Element.Path.CurveTo(
    PointF(CX - K * RX, CY + RY),
    PointF(CX - RX, CY + K * RY),
    PointF(CX - RX, CY)
  );
  Element.Path.CurveTo(
    PointF(CX - RX, CY - K * RY),
    PointF(CX - K * RX, CY - RY),
    PointF(CX, CY - RY)
  );
  Element.Path.CurveTo(
    PointF(CX + K * RX, CY - RY),
    PointF(CX + RX, CY - K * RY),
    PointF(CX + RX, CY)
  );
  Element.Path.ClosePath;
end;

procedure TSvgDocument.ParseLine(Node: IXMLNode; Element: TSvgElement);
begin
  Element.Path.MoveTo(
    PointF(
      LengthAttr(Node, 'x1', FWidth),
      LengthAttr(Node, 'y1', FHeight)
    )
  );
  Element.Path.LineTo(
    PointF(
      LengthAttr(Node, 'x2', FWidth),
      LengthAttr(Node, 'y2', FHeight)
    )
  );
end;

procedure TSvgDocument.ParsePoly(Node: IXMLNode; Element: TSvgElement; Closed: Boolean);
begin
  var Parser := TSvgNumberParser.Create(Attr(Node, 'points'));
  var I := 0;
  var X, Y: Single;
  while Parser.ReadNumber(X) do
  begin
    if not Parser.ReadNumber(Y) then
      Break;
    var P := PointF(X, Y);
    if I = 0 then
      Element.Path.MoveTo(P)
    else
      Element.Path.LineTo(P);
    Inc(I);
  end;
  if Closed and (I > 0) then
    Element.Path.ClosePath;
end;

procedure TSvgDocument.ParseShape(const Node: IXMLNode; const Matrix: TSvgMatrix; const Style: TSvgStyle);
begin
  var Name := Node.NodeName.ToLower;
  if Name = 'clippath' then
  begin
    ParseClipPath(Node, Matrix);
    Exit;
  end;
  if (Name <> 'path') and
    not ContainsString(['rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon'], Name) then
    Exit;
  var Element := TSvgElement.Create;
  Element.Name := Name;
  var TitleNode := Node;
  while TitleNode <> nil do
  begin
    var Title := TitleNode.ChildNodes.FindNode('title');
    if Title <> nil then
    begin
      Element.OutputName := Title.Text.Trim;
      Break;
    end;
    TitleNode := TitleNode.ParentNode;
  end;
  Element.Matrix := Matrix;
  Element.Style := Style;
  Element.ClipID := Attr(Node, 'clip-path');
  if Name = 'path' then
    ParsePath(Node, Element)
  else if Name = 'rect' then
    ParseRect(Node, Element)
  else if Name = 'circle' then
    ParseCircle(Node, Element)
  else if Name = 'ellipse' then
    ParseEllipse(Node, Element)
  else if Name = 'line' then
    ParseLine(Node, Element)
  else if Name = 'polyline' then
    ParsePoly(Node, Element, False)
  else if Name = 'polygon' then
    ParsePoly(Node, Element, True);
  FElements.Add(Element);
end;

procedure TSvgDocument.ParseClipPath(Node: IXMLNode; const Matrix: TSvgMatrix);
begin
  var ID := Attr(Node, 'id');
  if ID.IsEmpty then
    Exit;
  var Path := TSvgPath.Create;
  try
    for var I := 0 to Node.ChildNodes.Count - 1 do
    begin
      var Child := Node.ChildNodes[I];
      var Temp := TSvgElement.Create;
      try
        var Name := Child.NodeName.ToLower;
        if Name = 'path' then
          ParsePath(Child, Temp)
        else if Name = 'rect' then
          ParseRect(Child, Temp)
        else if Name = 'circle' then
          ParseCircle(Child, Temp)
        else if Name = 'ellipse' then
          ParseEllipse(Child, Temp)
        else
          Continue;
        for var Command in Temp.Path.Commands do
          Path.Commands.Add(Command);
      finally
        Temp.Free;
      end;
    end;
    FClipPaths.AddOrSetValue(ID, Path);
    Path := nil;
  finally
    Path.Free;
  end;
end;

procedure TSvgDocument.ParseLinearGradient(Node: IXMLNode);
begin
  var ID := Attr(Node, 'id');
  if ID.IsEmpty then
    Exit;
  var Definition := TSvgGradient.Create;
  try
    Definition.X1 := TSvgLength.Parse(Attr(Node, 'x1', '0%')).Resolve(1, 16);
    Definition.Y1 := TSvgLength.Parse(Attr(Node, 'y1', '0%')).Resolve(1, 16);
    Definition.X2 := TSvgLength.Parse(Attr(Node, 'x2', '100%')).Resolve(1, 16);
    Definition.Y2 := TSvgLength.Parse(Attr(Node, 'y2', '0%')).Resolve(1, 16);
    Definition.Matrix := ParseTransform(Attr(Node, 'gradientTransform'));
    for var I := 0 to Node.ChildNodes.Count - 1 do
    begin
      var Stop := Node.ChildNodes[I];
      if not SameText(Stop.NodeName, 'stop') then
        Continue;
      var Offset := EnsureRange(TSvgLength.Parse(StyleAttr(Stop, 'offset', '0')).Resolve(1, 16), 0, 1);
      var Color := ParseColor(StyleAttr(Stop, 'stop-color', 'black'), TAlphaColorRec.Black);
      var Opacity := EnsureRange(ParseFloat(StyleAttr(Stop, 'stop-opacity', '1'), 1), 0, 1);
      var Point := TGradientPoint(Definition.Gradient.Points.Add);
      Point.Offset := Offset;
      Point.Color := AlphaColorWithOpacity(Color, Opacity);
    end;
    if Definition.Gradient.Points.Count > 0 then
    begin
      FGradients.AddOrSetValue(ID, Definition);
      Definition := nil;
    end;
  finally
    Definition.Free;
  end;
end;

procedure TSvgDocument.ParseNode(const Node: IXMLNode; const ParentMatrix: TSvgMatrix; const ParentStyle: TSvgStyle);
begin
  var Style := ParseStyle(Node, ParentStyle);
  var Matrix := ParentMatrix * ParseTransform(Attr(Node, 'transform'));
  var Name := Node.NodeName.ToLower;
  if Name = 'lineargradient' then
  begin
    ParseLinearGradient(Node);
    Exit;
  end;
  if Name = 'defs' then
  begin
    for var I := 0 to Node.ChildNodes.Count - 1 do
      if SameText(Node.ChildNodes[I].NodeName, 'clippath') or
        SameText(Node.ChildNodes[I].NodeName, 'lineargradient') then
        ParseNode(Node.ChildNodes[I], Matrix, Style);
    Exit;
  end;
  if (Name = 'svg') or
    (Name = 'g') then
  begin
    if Name = 'svg' then
    begin
      FWidthLength := TSvgLength.Parse(Attr(Node, 'width'), 0);
      FHeightLength := TSvgLength.Parse(Attr(Node, 'height'), 0);
      FWidth := FWidthLength.Resolve(0, 16);
      FHeight := FHeightLength.Resolve(0, 16);
      var ViewBox := Attr(Node, 'viewBox');
      if not ViewBox.IsEmpty then
      begin
        var Parser := TSvgNumberParser.Create(ViewBox);
        var X, Y, W, H: Single;
        if Parser.ReadNumber(X) and
          Parser.ReadNumber(Y) and
          Parser.ReadNumber(W) and
          Parser.ReadNumber(H) then
        begin
          if (W > 0) and
            (H > 0) then
          begin
            FViewBox := RectF(X, Y, X + W, Y + H);
            FHasViewBox := True;
          end;
        end;
      end;
    end;
    for var I := 0 to Node.ChildNodes.Count - 1 do
      ParseNode(Node.ChildNodes[I], Matrix, Style);
    Exit;
  end;
  ParseShape(Node, Matrix, Style);
end;

procedure TSvgDocument.LoadFromString(const S: string);
begin
  Clear;
  if S.Trim.IsEmpty then
    Exit;
  var Xml: IXMLDocument :=
    TXMLDocument.Create(nil);
  Xml.LoadFromXML(S);
  if Xml.DocumentElement = nil then
    Exit;
  ParseNode(Xml.DocumentElement, TSvgMatrix.Identity, TSvgStyle.Default);
end;

{ TSvgControl }

constructor TSvgControl.Create(AOwner: TComponent);
begin
  inherited;
  FDocument := TSvgDocument.Create;
  FBitmap := TBitmap.Create(1, 1);
  FRenderScale := 1;
  FDocumentDirty := True;
  FBitmapDirty := True;
  CanFocus := False;
end;

destructor TSvgControl.Destroy;
begin
  FBitmap.Free;
  FDocument.Free;
  inherited;
end;

procedure TSvgControl.SetSVG(const Value: string);
begin
  if FSVG = Value then
    Exit;
  FSVG := Value;
  FDocumentDirty := True;
  FBitmapDirty := True;
  Repaint;
end;

procedure TSvgControl.SetRenderScale(const Value: Single);
begin
  var V := Max(Value, 0.01);
  if SameValue(FRenderScale, V, 0.0001) then
    Exit;
  FRenderScale := V;
  FBitmapDirty := True;
  Repaint;
end;

procedure TSvgControl.Reload;
begin
  FDocumentDirty := True;
  FBitmapDirty := True;
  Repaint;
end;

procedure TSvgControl.Resize;
begin
  inherited;
  FBitmapDirty := True;
end;

procedure TSvgControl.EnsureDocument;
begin
  if not FDocumentDirty then
    Exit;
  FDocument.LoadFromString(FSVG);
  FDocumentDirty := False;
end;

procedure TSvgControl.EnsureBitmap;
begin
  var W := Max(1, Ceil(Width * FRenderScale));
  var H := Max(1, Ceil(Height * FRenderScale));
  if (FBitmap.Width <> W) or
    (FBitmap.Height <> H) then
  begin
    FBitmap.SetSize(W, H);
    FBitmapDirty := True;
  end;
end;

function TSvgControl.GetContentMatrix: TSvgMatrix;
begin
  Result := TSvgMatrix.Identity;
  var ViewportWidth := FBitmap.Width;
  var ViewportHeight := FBitmap.Height;
  if FDocument.HasViewBox then
  begin
    var VB := FDocument.ViewBox;
    if (VB.Width <= 0) or
      (VB.Height <= 0) then
      Exit;
    var SX := ViewportWidth / VB.Width;
    var SY := ViewportHeight / VB.Height;
    var S := Min(SX, SY);
    var TX := (ViewportWidth - VB.Width * S) / 2 - VB.Left * S;
    var TY := (ViewportHeight - VB.Height * S) / 2 - VB.Top * S;
    Result := TSvgMatrix.Translation(TX, TY) * TSvgMatrix.Scaling(S, S);
    Exit;
  end;
  var ScaleX := FRenderScale;
  var ScaleY := FRenderScale;
  if FDocument.Width > 0 then
    ScaleX := ViewportWidth / FDocument.Width;
  if FDocument.Height > 0 then
    ScaleY := ViewportHeight / FDocument.Height;
  Result := TSvgMatrix.Scaling(ScaleX, ScaleY);
end;

procedure TSvgControl.RenderElement(const Canvas: TCanvas; Element: TSvgElement; const ViewMatrix: TSvgMatrix);
begin
  if not Element.Style.Visible then
    Exit;
  var Path := TPathData.Create;
  try
    var Matrix := ViewMatrix * Element.Matrix;
    Element.Path.AppendTo(Path, Matrix);
    var Opacity := EnsureRange(Element.Style.Opacity, 0, 1);
    if Element.Style.Fill.Enabled then
    begin
      var Brush := TBrush.Create(TBrushKind.Solid, TAlphaColorRec.Null);
      try
        var GradientDefinition: TSvgGradient;
        if not Element.Style.Fill.GradientID.IsEmpty and
          FDocument.Gradients.TryGetValue(Element.Style.Fill.GradientID, GradientDefinition) then
        begin
          Brush.Kind := TBrushKind.Gradient;
          Brush.Gradient.Style := TGradientStyle.Linear;
          var StartPoint := GradientDefinition.Matrix.TransformPoint(PointF(GradientDefinition.X1, GradientDefinition.Y1));
          var StopPoint := GradientDefinition.Matrix.TransformPoint(PointF(GradientDefinition.X2, GradientDefinition.Y2));
          Brush.Gradient.StartPosition.Point := StartPoint;
          Brush.Gradient.StopPosition.Point := StopPoint;
          Brush.Gradient.Points.Clear;
          for var I := 0 to GradientDefinition.Gradient.Points.Count - 1 do
          begin
            var SourcePoint := GradientDefinition.Gradient.Points[I];
            var TargetPoint := TGradientPoint(Brush.Gradient.Points.Add);
            TargetPoint.Offset := SourcePoint.Offset;
            TargetPoint.Color := AlphaColorWithOpacity(SourcePoint.Color, Element.Style.FillOpacity);
          end;
          Canvas.FillPath(Path, Opacity, Brush);
        end
        else if Element.Style.Fill.GradientID.IsEmpty then
        begin
          Brush.Color := AlphaColorWithOpacity(Element.Style.Fill.Color, Element.Style.FillOpacity);
          Canvas.FillPath(Path, Opacity, Brush);
        end;
      finally
        Brush.Free;
      end;
    end;
    if Element.Style.Stroke.Enabled and
      (Element.Style.StrokeWidth > 0) then
    begin
      var Stroke := TStrokeBrush.Create(TBrushKind.Solid, TAlphaColorRec.Null);
      try
        Stroke.Color := AlphaColorWithOpacity(Element.Style.Stroke.Color, Element.Style.StrokeOpacity);
        Stroke.Thickness := Element.Style.StrokeWidth;
        Canvas.DrawPath(Path, Opacity, Stroke);
      finally
        Stroke.Free;
      end;
    end;
  finally
    Path.Free;
  end;
end;

procedure TSvgControl.Rasterize;
begin
  EnsureDocument;
  EnsureBitmap;
  FBitmap.Canvas.BeginScene;
  try
    FBitmap.Canvas.Clear(TAlphaColorRec.Null);
    var Matrix := GetContentMatrix;
    for var Element in FDocument.Elements do
      RenderElement(FBitmap.Canvas, Element, Matrix);
  finally
    FBitmap.Canvas.EndScene;
  end;
  FBitmapDirty := False;
end;

procedure TSvgControl.RenderToBitmap(Bitmap: TBitmap; const Filter: TFunc<TSvgElement, Boolean>);
begin
  EnsureDocument;
  EnsureBitmap;
  if not Bitmap.Canvas.BeginScene then
    raise EInvalidOperation.Create('FMX cannot create SVG raster canvas');
  try
    Bitmap.Canvas.Clear(TAlphaColorRec.Null);
    var Matrix := GetContentMatrix;
    for var Element in FDocument.Elements do
      if not Assigned(Filter) or Filter(Element) then
        RenderElement(Bitmap.Canvas, Element, Matrix);
  finally
    Bitmap.Canvas.EndScene;
  end;
end;

procedure TSvgControl.Paint;
begin
  inherited;
  if FBitmapDirty then
    Rasterize;
  if (FBitmap <> nil) and
    (FBitmap.Width > 0) and
    (FBitmap.Height > 0) then
  begin
    Canvas.DrawBitmap(
      FBitmap,
      RectF(0, 0, FBitmap.Width, FBitmap.Height),
      LocalRect,
      AbsoluteOpacity
    );
  end;
end;

procedure Register;
begin
  RegisterComponents('Samples', [TSvgControl]);
end;

end.


