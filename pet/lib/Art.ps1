# 海绵宝宝矢量形象：XAML 定义 + 命名元素索引（表情/动画由主程序切换可见性与变换）。

$script:PetCanvasXaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="220" Height="284" Background="Transparent">
  <Canvas.RenderTransform>
    <TranslateTransform x:Name="BobTransform" X="0" Y="0"/>
  </Canvas.RenderTransform>

  <!-- 地面投影 -->
  <Ellipse Canvas.Left="48" Canvas.Top="256" Width="124" Height="18" Fill="#33000000"/>

  <!-- 腿与鞋 -->
  <Line X1="86" Y1="222" X2="86" Y2="248" Stroke="#1B1B1B" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Line X1="134" Y1="222" X2="134" Y2="248" Stroke="#1B1B1B" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
  <Rectangle Canvas.Left="64" Canvas.Top="246" Width="40" Height="14" RadiusX="6" RadiusY="6" Fill="#1B1B1B"/>
  <Rectangle Canvas.Left="116" Canvas.Top="246" Width="40" Height="14" RadiusX="6" RadiusY="6" Fill="#1B1B1B"/>

  <!-- 手臂（可绕肩旋转） -->
  <Canvas x:Name="LeftArm">
    <Canvas.RenderTransform>
      <RotateTransform x:Name="LeftArmRotate" Angle="0" CenterX="46" CenterY="156"/>
    </Canvas.RenderTransform>
    <Line X1="46" Y1="156" X2="20" Y2="126" Stroke="#1B1B1B" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    <Ellipse Canvas.Left="8" Canvas.Top="112" Width="26" Height="26" Fill="#FFFFFF" Stroke="#1B1B1B" StrokeThickness="2.5"/>
    <Line X1="15" Y1="120" X2="15" Y2="112" Stroke="#1B1B1B" StrokeThickness="1.6"/>
    <Line X1="21" Y1="118" X2="21" Y2="110" Stroke="#1B1B1B" StrokeThickness="1.6"/>
    <Line X1="27" Y1="120" X2="27" Y2="112" Stroke="#1B1B1B" StrokeThickness="1.6"/>
  </Canvas>
  <Canvas x:Name="RightArm">
    <Canvas.RenderTransform>
      <RotateTransform x:Name="RightArmRotate" Angle="0" CenterX="174" CenterY="156"/>
    </Canvas.RenderTransform>
    <Line X1="174" Y1="156" X2="200" Y2="126" Stroke="#1B1B1B" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    <Ellipse Canvas.Left="186" Canvas.Top="112" Width="26" Height="26" Fill="#FFFFFF" Stroke="#1B1B1B" StrokeThickness="2.5"/>
    <Line X1="193" Y1="120" X2="193" Y2="112" Stroke="#1B1B1B" StrokeThickness="1.6"/>
    <Line X1="199" Y1="118" X2="199" Y2="110" Stroke="#1B1B1B" StrokeThickness="1.6"/>
    <Line X1="205" Y1="120" X2="205" Y2="112" Stroke="#1B1B1B" StrokeThickness="1.6"/>
  </Canvas>

  <!-- 裤子与衬衫 -->
  <Rectangle Canvas.Left="40" Canvas.Top="188" Width="140" Height="36" RadiusX="8" RadiusY="8" Fill="#8B5A2B"/>
  <Rectangle Canvas.Left="40" Canvas.Top="186" Width="140" Height="8" Fill="#1B1B1B"/>
  <Rectangle Canvas.Left="40" Canvas.Top="170" Width="140" Height="18" Fill="#FFFFFF"/>
  <Path Fill="#FFFFFF" Data="M 78,170 L 110,196 L 142,170 Z"/>
  <Path Fill="#C0392B" Data="M 110,172 L 122,186 L 110,216 L 98,186 Z"/>

  <!-- 海绵身体 -->
  <Rectangle Canvas.Left="40" Canvas.Top="52" Width="140" Height="126" RadiusX="16" RadiusY="16" Fill="#F6E14B" Stroke="#CBA41F" StrokeThickness="2.5"/>
  <Ellipse Canvas.Left="54" Canvas.Top="66" Width="13" Height="11" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="150" Canvas.Top="86" Width="15" Height="12" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="66" Canvas.Top="140" Width="12" Height="10" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="146" Canvas.Top="146" Width="11" Height="9" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="52" Canvas.Top="112" Width="9" Height="8" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="162" Canvas.Top="62" Width="9" Height="8" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="104" Canvas.Top="164" Width="10" Height="8" Fill="#E4CD36"/>
  <Ellipse Canvas.Left="86" Canvas.Top="58" Width="8" Height="7" Fill="#E4CD36"/>

  <!-- 眼睛 -->
  <Ellipse x:Name="EyeL" Canvas.Left="64" Canvas.Top="78" Width="38" Height="46" Fill="#FFFFFF" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Ellipse x:Name="EyeR" Canvas.Left="99" Canvas.Top="78" Width="38" Height="46" Fill="#FFFFFF" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Ellipse x:Name="IrisL" Canvas.Left="75" Canvas.Top="92" Width="16" Height="20" Fill="#3E9BDE"/>
  <Ellipse x:Name="IrisR" Canvas.Left="110" Canvas.Top="92" Width="16" Height="20" Fill="#3E9BDE"/>
  <Ellipse x:Name="PupilL" Canvas.Left="79" Canvas.Top="98" Width="8" Height="10" Fill="#111111"/>
  <Ellipse x:Name="PupilR" Canvas.Left="114" Canvas.Top="98" Width="8" Height="10" Fill="#111111"/>
  <Ellipse x:Name="GlintL" Canvas.Left="77" Canvas.Top="94" Width="4" Height="4" Fill="#FFFFFF"/>
  <Ellipse x:Name="GlintR" Canvas.Left="112" Canvas.Top="94" Width="4" Height="4" Fill="#FFFFFF"/>
  <Path x:Name="EyeLineL" Stroke="#1B1B1B" StrokeThickness="3" Data="M 66,102 Q 83,116 100,102" Visibility="Collapsed"/>
  <Path x:Name="EyeLineR" Stroke="#1B1B1B" StrokeThickness="3" Data="M 101,102 Q 118,116 135,102" Visibility="Collapsed"/>
  <Path x:Name="EyeXL1" Stroke="#1B1B1B" StrokeThickness="3" Data="M 70,88 L 96,114" Visibility="Collapsed"/>
  <Path x:Name="EyeXL2" Stroke="#1B1B1B" StrokeThickness="3" Data="M 96,88 L 70,114" Visibility="Collapsed"/>
  <Path x:Name="EyeXR1" Stroke="#1B1B1B" StrokeThickness="3" Data="M 105,88 L 131,114" Visibility="Collapsed"/>
  <Path x:Name="EyeXR2" Stroke="#1B1B1B" StrokeThickness="3" Data="M 131,88 L 105,114" Visibility="Collapsed"/>
  <!-- 睫毛 -->
  <Line X1="70" Y1="80" X2="70" Y2="70" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Line X1="83" Y1="76" X2="84" Y2="66" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Line X1="96" Y1="80" X2="97" Y2="70" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Line X1="105" Y1="80" X2="104" Y2="70" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Line X1="118" Y1="76" X2="117" Y2="66" Stroke="#1B1B1B" StrokeThickness="2.5"/>
  <Line X1="131" Y1="80" X2="131" Y2="70" Stroke="#1B1B1B" StrokeThickness="2.5"/>

  <!-- 腮红与雀斑 -->
  <Ellipse Canvas.Left="44" Canvas.Top="132" Width="24" Height="15" Fill="#F4A6B8" Opacity="0.85"/>
  <Ellipse Canvas.Left="152" Canvas.Top="132" Width="24" Height="15" Fill="#F4A6B8" Opacity="0.85"/>
  <Ellipse Canvas.Left="50" Canvas.Top="136" Width="3" Height="3" Fill="#B9782F"/>
  <Ellipse Canvas.Left="57" Canvas.Top="141" Width="3" Height="3" Fill="#B9782F"/>
  <Ellipse Canvas.Left="160" Canvas.Top="136" Width="3" Height="3" Fill="#B9782F"/>
  <Ellipse Canvas.Left="167" Canvas.Top="141" Width="3" Height="3" Fill="#B9782F"/>

  <!-- 嘴 -->
  <Path x:Name="MouthSmile" Stroke="#6B3F1D" StrokeThickness="3.2" Fill="Transparent"
        Data="M 86,144 Q 110,170 134,144"/>
  <Rectangle Canvas.Left="101" Canvas.Top="141" Width="8.5" Height="12" Fill="#FFFFFF" Stroke="#6B3F1D" StrokeThickness="1.6"/>
  <Rectangle Canvas.Left="110" Canvas.Top="141" Width="8.5" Height="12" Fill="#FFFFFF" Stroke="#6B3F1D" StrokeThickness="1.6"/>
  <Path x:Name="MouthOpen" Fill="#7A2E22" Visibility="Collapsed"
        Data="M 90,142 Q 110,184 130,142 Q 110,152 90,142 Z"/>
  <Ellipse x:Name="MouthO" Canvas.Left="102" Canvas.Top="144" Width="16" Height="14" Fill="#7A2E22" Visibility="Collapsed"/>
  <Path x:Name="MouthWave" Stroke="#6B3F1D" StrokeThickness="3" Visibility="Collapsed"
        Data="M 88,156 Q 96,148 104,156 Q 112,164 120,156 Q 128,148 134,156"/>

  <!-- 状态点缀 -->
  <Path x:Name="SweatL" Fill="#7FD3F7" Stroke="#3E9BDE" StrokeThickness="1.5" Visibility="Collapsed"
        Data="M 172,58 C 178,68 182,74 176,80 C 170,84 164,78 166,70 Z"/>
  <Path x:Name="SweatR" Fill="#7FD3F7" Stroke="#3E9BDE" StrokeThickness="1.5" Visibility="Collapsed"
        Data="M 44,64 C 38,74 34,80 40,86 C 46,90 52,84 50,76 Z"/>
  <TextBlock x:Name="Exclaim" Canvas.Left="186" Canvas.Top="46" FontFamily="Segoe UI" FontSize="28" FontWeight="Bold"
             Foreground="#E03131" Text="!" Visibility="Collapsed"/>
  <TextBlock x:Name="Zzz" Canvas.Left="182" Canvas.Top="48" FontFamily="Segoe UI" FontSize="19" FontWeight="Bold"
             Foreground="#4A6FA5" Text="z Z" Visibility="Collapsed"/>
  <TextBlock x:Name="ThinkDots" Canvas.Left="184" Canvas.Top="56" FontFamily="Segoe UI" FontSize="20" FontWeight="Bold"
             Foreground="#4A6FA5" Text="…" Visibility="Collapsed"/>

  <!-- 庆祝：派对帽 + 飘落的彩纸（只在 celebrate 状态显示）-->
  <Canvas x:Name="PartyHat" Visibility="Collapsed">
    <Path Fill="#E03131" Data="M 110,6 L 94,44 L 126,44 Z"/>
    <Path Fill="#C0392B" Data="M 110,6 L 102,25 L 118,25 Z"/>
    <Ellipse Canvas.Left="103" Canvas.Top="0" Width="14" Height="14" Fill="#F6E14B"/>
    <Ellipse Canvas.Left="90" Canvas.Top="38" Width="40" Height="8" Fill="#3E9BDE"/>
  </Canvas>
  <Canvas x:Name="Confetti" Visibility="Collapsed">
    <Rectangle x:Name="Conf1" Canvas.Left="34" Canvas.Top="70" Width="9" Height="9" Fill="#E03131">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr1" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="Conf2" Canvas.Left="182" Canvas.Top="62" Width="9" Height="9" Fill="#3E9BDE">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr2" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="Conf3" Canvas.Left="18" Canvas.Top="130" Width="8" Height="8" Fill="#1A9F5B">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr3" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="Conf4" Canvas.Left="196" Canvas.Top="122" Width="8" Height="8" Fill="#F6E14B">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr4" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="Conf5" Canvas.Left="52" Canvas.Top="30" Width="7" Height="7" Fill="#9B59B6">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr5" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="Conf6" Canvas.Left="168" Canvas.Top="24" Width="7" Height="7" Fill="#E67E22">
      <Rectangle.RenderTransform><TranslateTransform x:Name="ConfTr6" X="0" Y="0"/></Rectangle.RenderTransform>
    </Rectangle>
  </Canvas>

  <!-- 台词气泡 -->
  <Canvas x:Name="StatusBubble" Visibility="Collapsed">
    <Rectangle Canvas.Left="12" Canvas.Top="2" Width="196" Height="44" RadiusX="14" RadiusY="14"
               Fill="#FFFDF0" Stroke="#CBA41F" StrokeThickness="2"/>
    <Path Fill="#FFFDF0" Stroke="#CBA41F" StrokeThickness="2" Data="M 100,46 L 112,60 L 122,46 Z"/>
    <TextBlock x:Name="StatusText" Canvas.Left="24" Canvas.Top="12" Width="172" Height="26"
               FontFamily="Microsoft YaHei" FontSize="13" FontWeight="Bold" Foreground="#5A4410"
               TextTrimming="CharacterEllipsis" TextAlignment="Center" Text=""/>
  </Canvas>
</Canvas>
'@

function New-PetVisual {
  [xml]$xaml = $script:PetCanvasXaml
  $reader = New-Object System.Xml.XmlNodeReader $xaml
  $root = [System.Windows.Markup.XamlReader]::Load($reader)

  $names = @(
    'BobTransform','LeftArm','RightArm','LeftArmRotate','RightArmRotate',
    'EyeL','EyeR','IrisL','IrisR','PupilL','PupilR','GlintL','GlintR',
    'EyeLineL','EyeLineR','EyeXL1','EyeXL2','EyeXR1','EyeXR2',
    'MouthSmile','MouthOpen','MouthO','MouthWave',
    'SweatL','SweatR','Exclaim','Zzz','ThinkDots','StatusBubble','StatusText',
    'PartyHat','Confetti',
    'ConfTr1','ConfTr2','ConfTr3','ConfTr4','ConfTr5','ConfTr6'
  )
  $elements = @{}
  foreach ($name in $names) { $elements[$name] = $root.FindName($name) }

  # 外面再包一层做「吸附姿态」：贴到屏幕边缘时在这一层倾斜/翻转，里面的 BobTransform 继续管呼吸与蹦跳。
  # 绕中心旋转，再整体平移一点让身体像是从边缘后面探出来。
  $dockHost = New-Object System.Windows.Controls.Grid
  $dockHost.Children.Add($root) | Out-Null
  $dockScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
  $dockRotate = New-Object System.Windows.Media.RotateTransform(0)
  $dockShift = New-Object System.Windows.Media.TranslateTransform(0, 0)
  $dockGroup = New-Object System.Windows.Media.TransformGroup
  $dockGroup.Children.Add($dockScale) | Out-Null
  $dockGroup.Children.Add($dockRotate) | Out-Null
  $dockGroup.Children.Add($dockShift) | Out-Null
  $dockHost.RenderTransform = $dockGroup
  $dockHost.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  $elements['DockScale'] = $dockScale
  $elements['DockRotate'] = $dockRotate
  $elements['DockShift'] = $dockShift

  return [pscustomobject]@{ Root = $dockHost; Elements = $elements }
}
