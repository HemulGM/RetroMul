unit RetroTune.ReferenceForm;

interface

uses
  System.Classes, System.Types, FMX.Forms, FMX.Layouts, FMX.Edit, FMX.StdCtrls;

type
  TTuneReferenceForm = class(TForm)
  private
    FTitleLabel, FSubtitleLabel: TLabel;
    FSection: TLayout;
    FCard: TPanel;
    FContentHeight: Single;
    FRowCount: Integer;
    FPage, FHeader: TLayout;
    FBackground: TPanel;
    FCloseButton: TButton;
    FUpdatingLayout: Boolean;
    procedure UpdateLayout(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    {$IF CompilerVersion >= 37.0}
    procedure SafeAreaChanged(Sender: TObject; const Insets: TRectF);
    {$ENDIF}
  protected
    FScroll: TVertScrollBox;
    procedure SetHeading(const Title, Subtitle: string);
    procedure ClearContent;
    procedure AddSection(const Title: string);
    function AddField(const Name, Value: string): TEdit;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  System.UITypes, System.Math, FMX.Types, FMX.Controls, FMX.BehaviorManager;

type
  TTuneReferenceRow = class(TLayout)
  public
    NameLabel: TLabel;
    ValueEdit: TEdit;
  end;

constructor TTuneReferenceForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'RetroTune';
  ClientWidth := 880;
  ClientHeight := 760;
  Constraints.MinWidth := 320;
  Constraints.MinHeight := 240;
  {$IFDEF MOBILE}
  Constraints.MinWidth := 0;
  Constraints.MinHeight := 0;
  {$ENDIF}
  Position := TFormPosition.ScreenCenter;
  var Background := TPanel.Create(Self);
  FBackground := Background;
  Background.Parent := Self;
  Background.Align := TAlignLayout.Contents;
  Background.StyleLookup := 'panelstyle_appbackground';
  var Page := TLayout.Create(Self);
  FPage := Page;
  Page.Parent := Background;
  Page.Align := TAlignLayout.Client;
  Page.Margins.Left := 24;
  Page.Margins.Right := 24;
  Page.Margins.Top := 24;
  Page.Margins.Bottom := 24;
  var Header := TLayout.Create(Self);
  FHeader := Header;
  Header.Parent := Page;
  Header.OnResize := UpdateLayout;
  Header.Align := TAlignLayout.Top;
  Header.Height := 68;
  Header.Margins.Bottom := 24;
  FTitleLabel := TLabel.Create(Self);
  FTitleLabel.Name := 'LabelReferenceTitle';
  FTitleLabel.Parent := Header;
  FTitleLabel.Align := TAlignLayout.Top;
  FTitleLabel.Height := 36;
  FTitleLabel.StyleLookup := 'labelstyle_title';
  FTitleLabel.StyledSettings := FTitleLabel.StyledSettings - [TStyledSetting.Other];
  FTitleLabel.TextSettings.Trimming := TTextTrimming.Character;
  FTitleLabel.Text := 'RetroTune';
  FSubtitleLabel := TLabel.Create(Self);
  FSubtitleLabel.Name := 'LabelReferenceSubtitle';
  FSubtitleLabel.Parent := Header;
  FSubtitleLabel.Align := TAlignLayout.Bottom;
  FSubtitleLabel.Height := 20;
  FSubtitleLabel.StyleLookup := 'labelstyle_caption';
  FSubtitleLabel.StyledSettings := FSubtitleLabel.StyledSettings - [TStyledSetting.Other];
  FSubtitleLabel.TextSettings.WordWrap := False;
  FSubtitleLabel.TextSettings.Trimming := TTextTrimming.Character;
  FCloseButton := TButton.Create(Self);
  FCloseButton.Name := 'ButtonCloseReference';
  FCloseButton.Parent := Header;
  FCloseButton.Text := '×';
  FCloseButton.Hint := Translate('Close');
  FCloseButton.OnClick := CloseClick;
  FScroll := TVertScrollBox.Create(Self);
  FScroll.Parent := Page;
  FScroll.Align := TAlignLayout.Client;
  FScroll.ScrollAnimation := TBehaviorBoolean.True;
  // Keep cards clear of the scroll bar, including when the window is narrow.
  FScroll.Padding.Right := 16;
  FScroll.OnResize := UpdateLayout;
  OnResize := UpdateLayout;
  {$IF CompilerVersion >= 37.0}
  OnSafeAreaChanged := SafeAreaChanged;
  {$ENDIF}
  UpdateLayout(nil);
end;

procedure TTuneReferenceForm.CloseClick(Sender: TObject);
begin
  Close;
end;

destructor TTuneReferenceForm.Destroy;
begin
  FUpdatingLayout := True;
  inherited;
end;

{$IF CompilerVersion >= 37.0}
procedure TTuneReferenceForm.SafeAreaChanged(Sender: TObject; const Insets: TRectF);
begin
  FBackground.Padding.Rect := Insets;
  UpdateLayout(nil);
end;
{$ENDIF}

procedure TTuneReferenceForm.UpdateLayout(Sender: TObject);
begin
  if FUpdatingLayout or (FScroll = nil) then Exit;
  FUpdatingLayout := True;
  try
    var Compact := ClientWidth - FBackground.Padding.Left - FBackground.Padding.Right < 600;
    var Inset: Single := 24;
    if Compact then Inset := 12;
    FPage.Margins.Rect := RectF(Inset, Inset, Inset, Inset);
    FHeader.Height := 80;
    FHeader.Margins.Bottom := Inset;
    FTitleLabel.Align := TAlignLayout.None;
    FTitleLabel.SetBounds(0, 0, Max(0, FHeader.Width - 52), 48);
    FTitleLabel.TextSettings.WordWrap := Compact;
    if Compact then FTitleLabel.StyleLookup := 'labelstyle_subtitle'
    else FTitleLabel.StyleLookup := 'labelstyle_title';
    FSubtitleLabel.Align := TAlignLayout.None;
    FSubtitleLabel.SetBounds(0, 56, FHeader.Width, 24);
    FSubtitleLabel.TextSettings.WordWrap := Compact;
    if Compact then
    begin
      FHeader.Height := 120;
      FTitleLabel.Height := 72;
      FSubtitleLabel.Position.Y := 80;
      FSubtitleLabel.Height := 40;
    end;
    FCloseButton.SetBounds(Max(0, FHeader.Width - 44), 0, 44, 44);
    FContentHeight := 0;
    for var SectionIndex := 0 to FScroll.Content.ChildrenCount - 1 do
    begin
      var Child := FScroll.Content.Children[SectionIndex];
      if Child is TLayout then
      begin
        var Section := TLayout(Child);
        var Card: TPanel := nil;
        for var ChildIndex := 0 to Section.ChildrenCount - 1 do
        begin
          var Item := Section.Children[ChildIndex];
          if Item is TPanel then Card := TPanel(Item);
        end;
        if Card = nil then Continue;
        var CardHeight: Single := 16;
        for var RowIndex := 0 to Card.ChildrenCount - 1 do
        begin
          var Item := Card.Children[RowIndex];
          if Item is TTuneReferenceRow then
          begin
            var Row := TTuneReferenceRow(Item);
            if (Row.NameLabel = nil) or (Row.ValueEdit = nil) then Continue;
            Row.NameLabel.Margins.Rect := TRectF.Empty;
            Row.ValueEdit.Margins.Rect := TRectF.Empty;
            if Compact then
            begin
              Row.Height := 84;
              Row.NameLabel.Align := TAlignLayout.Top;
              Row.NameLabel.Height := 24;
              Row.NameLabel.Margins.Bottom := 8;
              Row.ValueEdit.Align := TAlignLayout.Top;
              Row.ValueEdit.Height := 44;
            end
            else
            begin
              Row.Height := 40;
              Row.NameLabel.Align := TAlignLayout.Left;
              Row.NameLabel.Width := 224;
              Row.NameLabel.Margins.Right := 12;
              Row.ValueEdit.Align := TAlignLayout.Client;
              Row.ValueEdit.Margins.Top := 4;
              Row.ValueEdit.Margins.Bottom := 4;
            end;
            CardHeight := CardHeight + Row.Height;
          end
          else if Item is TPanel then
            CardHeight := CardHeight + TPanel(Item).Height;
        end;
        Card.Height := CardHeight;
        Section.Height := 32 + CardHeight;
        Section.Margins.Bottom := Inset;
        FContentHeight := FContentHeight + Section.Height + Inset;
      end;
    end;
    FScroll.InvalidateContentSize;
    FScroll.RealignContent;
  finally
    FUpdatingLayout := False;
  end;
end;

procedure TTuneReferenceForm.AddSection(const Title: string);
begin
  FSection := TLayout.Create(Self);
  FSection.Parent := FScroll.Content;
  FSection.Position.Y := FContentHeight;
  FSection.Align := TAlignLayout.Top;
  FSection.Height := 48;
  FSection.Margins.Bottom := 24;
  var Heading := TLabel.Create(Self);
  Heading.Parent := FSection;
  Heading.Align := TAlignLayout.Top;
  Heading.Height := 24;
  Heading.Margins.Bottom := 8;
  Heading.StyleLookup := 'labelstyle_bodystrong';
  Heading.Text := Translate(Title);
  FCard := TPanel.Create(Self);
  FCard.Parent := FSection;
  FCard.Position.Y := 32;
  FCard.Align := TAlignLayout.Top;
  FCard.Height := 16;
  // Use the WinUI theme's neutral card surface, border and rounded corners.
  FCard.StyleLookup := 'panelstyle';
  FCard.Padding.Left := 16;
  FCard.Padding.Right := 16;
  FCard.Padding.Top := 8;
  FCard.Padding.Bottom := 8;
  FRowCount := 0;
  FContentHeight := FContentHeight + 72;
end;

function TTuneReferenceForm.AddField(const Name, Value: string): TEdit;
const
  RowHeight = 40;
  DividerHeight = 1;
  EditHeight = 32;
begin
  if FRowCount > 0 then
  begin
    var Divider := TPanel.Create(Self);
    Divider.Parent := FCard;
    Divider.Position.Y := FRowCount * (RowHeight + DividerHeight) - DividerHeight;
    Divider.Align := TAlignLayout.Top;
    Divider.Height := DividerHeight;
    Divider.StyleLookup := 'panelstyle_divider';
    FContentHeight := FContentHeight + DividerHeight;
  end;
  var Row := TTuneReferenceRow.Create(Self);
  Row.Parent := FCard;
  Row.Position.Y := FRowCount * (RowHeight + DividerHeight);
  Row.Align := TAlignLayout.Top;
  Row.Height := RowHeight;
  Inc(FRowCount);
  FCard.Height := 16 + FRowCount * RowHeight + (FRowCount - 1) * DividerHeight;
  FSection.Height := 32 + FCard.Height;
  FContentHeight := FContentHeight + RowHeight;
  var LabelName := TLabel.Create(Self);
  Row.NameLabel := LabelName;
  LabelName.Parent := Row;
  LabelName.Align := TAlignLayout.Left;
  LabelName.Width := 224;
  LabelName.Margins.Right := 12;
  LabelName.Text := Translate(Name);
  LabelName.TextSettings.WordWrap := False;
  LabelName.TextSettings.Trimming := TTextTrimming.Character;
  LabelName.Hint := Translate(Name);
  Result := TEdit.Create(Self);
  Row.ValueEdit := Result;
  Result.Parent := Row;
  Result.Align := TAlignLayout.Client;
  Result.Margins.Top := (RowHeight - EditHeight) / 2;
  Result.Margins.Bottom := (RowHeight - EditHeight) / 2;
  Result.StyleLookup := 'editstyle_clear_sized';
  Result.ReadOnly := True;
  Result.AutoTranslate := False;
  Result.TextPrompt := Translate('Not specified');
  Result.Text := Value;
  Result.Hint := Value;
  UpdateLayout(nil);
end;

procedure TTuneReferenceForm.SetHeading(const Title, Subtitle: string);
begin
  Caption := Translate(Title);
  FTitleLabel.Text := Translate(Title);
  FSubtitleLabel.Text := Subtitle;
  FSubtitleLabel.Hint := Subtitle;
end;

procedure TTuneReferenceForm.ClearContent;
begin
  FCard := nil;
  FSection := nil;
  FScroll.Content.DeleteChildren;
  FContentHeight := 0;
end;

end.
