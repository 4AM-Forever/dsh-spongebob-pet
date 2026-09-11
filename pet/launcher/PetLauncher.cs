// 海绵宝宝桌宠的无控制台启动器。
// 用 /target:winexe 编译（Windows 子系统，不分配控制台）：双击它、快捷方式指向它、
// 或由 DSH 插件 spawn 它，都不会闪 cmd 窗口，也不会留一个最小化的控制台在任务栏。
// 它只做一件事：以 CreateNoWindow 方式拉起同目录的 SpongeBobPet.ps1，然后立刻退出。
// 重新编译：powershell -ExecutionPolicy RemoteSigned -File tools\build-launcher.ps1
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class PetLauncher
{
    [STAThread]
    private static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "SpongeBobPet.ps1");
        string log = Path.Combine(dir, "pet-launch.log");

        if (!File.Exists(script))
        {
            MessageBox.Show("找不到桌宠脚本：\n" + script, "海绵宝宝桌宠", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string shell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0\powershell.exe");

        ProcessStartInfo info = new ProcessStartInfo();
        info.FileName = File.Exists(shell) ? shell : "powershell.exe";
        info.Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -STA -File \"" + script + "\"";
        info.UseShellExecute = false;
        // 关键：不创建控制台窗口。这样桌宠只留自己的 WPF 窗口，任务栏里不会有黑框。
        info.CreateNoWindow = true;
        info.WorkingDirectory = dir;

        try
        {
            Process.Start(info);
        }
        catch (Exception error)
        {
            try
            {
                File.AppendAllText(log, DateTime.Now.ToString("s") + " 启动失败: " + error.Message + Environment.NewLine);
            }
            catch
            {
            }
            MessageBox.Show("启动桌宠失败：\n" + error.Message, "海绵宝宝桌宠", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
