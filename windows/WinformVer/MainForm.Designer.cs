using System.Drawing;
using System.Windows.Forms;

namespace FirestickCleanup
{
    partial class MainForm
    {
        private Label lblTitle;
        private Label lblDeviceIP;
        private TextBox txtDeviceIP;
        private Label lblLauncher;
        private ComboBox cmbLauncher;
        private Label lblLauncherSummary;
        private CheckBox chkHomeOnFire;
        private GroupBox grpOptions;
        private FlowLayoutPanel pnlOptions;
        private Button btnStart;
        private Button btnReapply;
        private Button btnStatus;
        private Button btnRevert;
        private ProgressBar progressBar;
        private Label lblStatus;
        private GroupBox grpLog;
        private TextBox txtLog;
        private ToolTip toolTip;

        private System.ComponentModel.IContainer components = null;

        protected override void Dispose(bool disposing)
        {
            if (disposing && components != null) components.Dispose();
            base.Dispose(disposing);
        }

        private void InitializeComponent()
        {
            this.components = new System.ComponentModel.Container();
            this.toolTip = new ToolTip(this.components);
            this.lblTitle = new Label();
            this.lblDeviceIP = new Label();
            this.txtDeviceIP = new TextBox();
            this.lblLauncher = new Label();
            this.cmbLauncher = new ComboBox();
            this.lblLauncherSummary = new Label();
            this.chkHomeOnFire = new CheckBox();
            this.grpOptions = new GroupBox();
            this.pnlOptions = new FlowLayoutPanel();
            this.btnStart = new Button();
            this.btnReapply = new Button();
            this.btnStatus = new Button();
            this.btnRevert = new Button();
            this.progressBar = new ProgressBar();
            this.lblStatus = new Label();
            this.grpLog = new GroupBox();
            this.txtLog = new TextBox();

            this.SuspendLayout();
            this.grpOptions.SuspendLayout();
            this.grpLog.SuspendLayout();

            // lblTitle
            this.lblTitle.AutoSize = true;
            this.lblTitle.Location = new Point(12, 10);
            this.lblTitle.Font = new Font("Segoe UI", 14F, FontStyle.Bold);
            this.lblTitle.Text = "Firestick Cleanup - Launcher replacement + debloat";

            // lblDeviceIP / txtDeviceIP
            this.lblDeviceIP.AutoSize = true;
            this.lblDeviceIP.Location = new Point(14, 52);
            this.lblDeviceIP.Text = "Fire TV IP:";
            this.txtDeviceIP.Location = new Point(90, 48);
            this.txtDeviceIP.Size = new Size(160, 23);
            this.toolTip.SetToolTip(this.txtDeviceIP, "Settings > My Fire TV > About > Network. An optional :port is accepted.");

            // lblLauncher / cmbLauncher / lblLauncherSummary
            this.lblLauncher.AutoSize = true;
            this.lblLauncher.Location = new Point(270, 52);
            this.lblLauncher.Text = "Launcher:";
            this.cmbLauncher.Location = new Point(340, 48);
            this.cmbLauncher.Size = new Size(190, 23);
            this.cmbLauncher.DropDownStyle = ComboBoxStyle.DropDownList;
            this.cmbLauncher.SelectedIndexChanged += new System.EventHandler(this.CmbLauncher_SelectedIndexChanged);
            this.lblLauncherSummary.AutoSize = true;
            this.lblLauncherSummary.Location = new Point(540, 52);
            this.lblLauncherSummary.ForeColor = SystemColors.GrayText;
            this.lblLauncherSummary.Text = "";

            // chkHomeOnFire
            this.chkHomeOnFire.AutoSize = true;
            this.chkHomeOnFire.Location = new Point(14, 80);
            this.chkHomeOnFire.Text = "Install Home on Fire (redirects the Home button to your launcher; required for Couchy, optional for Projectivy and AT4K)";
            this.toolTip.SetToolTip(this.chkHomeOnFire, "github.com/toolicious/home-on-fire. After install, pick your launcher under 'Choose target app' in the app.");

            // grpOptions / pnlOptions
            this.grpOptions.Location = new Point(12, 108);
            this.grpOptions.Size = new Size(836, 236);
            this.grpOptions.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            this.grpOptions.Text = "Optional Amazon apps to disable (tracking, telemetry, ads and background bloat are always disabled)";
            this.pnlOptions.Dock = DockStyle.Fill;
            this.pnlOptions.FlowDirection = FlowDirection.TopDown;
            this.pnlOptions.WrapContents = true;
            this.pnlOptions.AutoScroll = true;
            this.pnlOptions.Padding = new Padding(6, 4, 6, 4);
            this.grpOptions.Controls.Add(this.pnlOptions);

            // Buttons
            this.btnStart.Location = new Point(12, 354);
            this.btnStart.Size = new Size(150, 32);
            this.btnStart.Text = "Install + Clean";
            this.btnStart.Click += new System.EventHandler(this.BtnStart_Click);
            this.toolTip.SetToolTip(this.btnStart, "Install the launcher (and Home on Fire if ticked), then disable the selected packages.");

            this.btnReapply.Location = new Point(170, 354);
            this.btnReapply.Size = new Size(120, 32);
            this.btnReapply.Text = "Re-apply";
            this.btnReapply.Click += new System.EventHandler(this.BtnReapply_Click);
            this.toolTip.SetToolTip(this.btnReapply, "After a Fire OS update: re-disable packages and re-apply launcher settings using the saved choices (or the boxes ticked above).");

            this.btnStatus.Location = new Point(298, 354);
            this.btnStatus.Size = new Size(100, 32);
            this.btnStatus.Text = "Status";
            this.btnStatus.Click += new System.EventHandler(this.BtnStatus_Click);
            this.toolTip.SetToolTip(this.btnStatus, "Show what is installed and disabled. Changes nothing.");

            this.btnRevert.Location = new Point(406, 354);
            this.btnRevert.Size = new Size(120, 32);
            this.btnRevert.Text = "Revert";
            this.btnRevert.Click += new System.EventHandler(this.BtnRevert_Click);
            this.toolTip.SetToolTip(this.btnRevert, "Undo everything this tool recorded for the device and restore the Amazon launcher.");

            // progressBar / lblStatus
            this.progressBar.Location = new Point(12, 396);
            this.progressBar.Size = new Size(836, 18);
            this.progressBar.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            this.lblStatus.AutoSize = true;
            this.lblStatus.Location = new Point(12, 420);
            this.lblStatus.Text = "Ready.";

            // grpLog / txtLog
            this.grpLog.Location = new Point(12, 444);
            this.grpLog.Size = new Size(836, 296);
            this.grpLog.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            this.grpLog.Text = "Log";
            this.txtLog.Dock = DockStyle.Fill;
            this.txtLog.Multiline = true;
            this.txtLog.ReadOnly = true;
            this.txtLog.ScrollBars = ScrollBars.Vertical;
            this.txtLog.Font = new Font("Consolas", 9F);
            this.txtLog.BackColor = Color.White;
            this.grpLog.Controls.Add(this.txtLog);

            // MainForm
            this.ClientSize = new Size(860, 752);
            this.MinimumSize = new Size(876, 640);
            this.Controls.Add(this.lblTitle);
            this.Controls.Add(this.lblDeviceIP);
            this.Controls.Add(this.txtDeviceIP);
            this.Controls.Add(this.lblLauncher);
            this.Controls.Add(this.cmbLauncher);
            this.Controls.Add(this.lblLauncherSummary);
            this.Controls.Add(this.chkHomeOnFire);
            this.Controls.Add(this.grpOptions);
            this.Controls.Add(this.btnStart);
            this.Controls.Add(this.btnReapply);
            this.Controls.Add(this.btnStatus);
            this.Controls.Add(this.btnRevert);
            this.Controls.Add(this.progressBar);
            this.Controls.Add(this.lblStatus);
            this.Controls.Add(this.grpLog);
            this.Font = new Font("Segoe UI", 9F);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.Text = "Firestick Cleanup";

            this.grpOptions.ResumeLayout(false);
            this.grpLog.ResumeLayout(false);
            this.grpLog.PerformLayout();
            this.ResumeLayout(false);
            this.PerformLayout();
        }
    }
}
