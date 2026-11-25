Build a Shared Linux Package Repository with Amazon EFS and Nginx
Step-by-step implementation guide | Assumption: Amazon Linux 2023 EC2, Amazon EFS, Nginx, and AWS security groups.
 
1. What you are building
An EC2 web server mounts Amazon EFS over NFS (TCP 2049). Nginx publishes the EFS packages directory at the URL path /packages/. Other servers can mount the same EFS file system, download packages into it, and make those files available through the web server.
Important design point: Your Nginx configuration uses the alias directive, so a symbolic link is not required. The alias maps /packages/ directly to /mnt/efs/packages/. A symlink is an optional alternative, not something you need in addition to alias.

Permissions correction: Use 755 for directories and normally 644 for package files. Mode 655 gives execute permission to group/others; RPM and repository metadata files generally do not need that. Use 655 only if you have a specific requirement.

2. Prerequisites and AWS network setup
Before running Linux commands, prepare these AWS resources:
•	A VPC with the EC2 instance and EFS mount target able to communicate. They should be in the same VPC or have valid routing.
•	An EC2 security group for the web server. Allow inbound TCP 80 from the intended client networks; allow SSH only from trusted administration IPs.
•	An EFS security group. Add inbound NFS TCP 2049 with the source set to the web-server EC2 security group (not 0.0.0.0/0).
•	Create an EFS mount target in each Availability Zone where an EC2 instance needs low-latency access. Ensure network ACLs allow the traffic.
•	For multiple web servers, attach the same EFS file system to each server and deploy the same Nginx configuration on each.
Security-group flow: EC2 → EFS on TCP 2049. Security groups are stateful, so response traffic is automatically allowed.
 
Step 1 — Create the web server and install Nginx
Purpose: Launch an Amazon Linux 2023 EC2 instance, connect to it, and install Nginx.
sudo dnf update -y
sudo dnf install -y nginx
sudo systemctl enable --now nginx
sudo systemctl status nginx
What the command means: dnf = package manager; install = install software; -y = answer yes; systemctl = manage services; enable = start at boot; --now = start immediately; status = show service state.
If you choose Apache HTTP Server instead, install it with:
sudo dnf install -y httpd
sudo systemctl enable --now httpd
Choose one web server: The supplied package.conf is Nginx syntax. Use Nginx for the rest of this guide. Do not put that server block into Apache's configuration.

Step 2 — Create EFS and configure its security group
Purpose: Create an encrypted EFS file system (recommended), add mount targets in the required Availability Zones, and allow NFS from the EC2 security group.
EFS security group inbound rule:
Type: NFS
Protocol: TCP
Port: 2049
Source: <WEB_SERVER_SECURITY_GROUP_ID>
What the command means: NFS = Network File System. TCP 2049 is the standard NFS port. Restrict the source to the web-server security group.
In the EFS console, note the file-system ID, for example fs-0123456789abcdef0. Confirm that the EFS mount target is reachable from the EC2 subnet.
Step 3 — Install EFS mount utilities and mount EFS
Purpose: Install the EFS helper, create a mount directory, and mount the file system.
sudo dnf install -y amazon-efs-utils
sudo mkdir -p /mnt/efs
sudo mount -t efs -o tls fs-0123456789abcdef0:/ /mnt/efs

df -hT /mnt/efs
mount | grep /mnt/efs
What the command means: mkdir -p = create directory including missing parent directories; mount = attach a file system; -t efs = use EFS helper; -o tls = encrypt data in transit; df -hT = show mounted file-system type and size.
Replace the example ID: Substitute fs-0123456789abcdef0 with your actual EFS file-system ID. The EC2 instance must have network access to the EFS mount target.

Make the mount persistent after reboot
sudo cp -p /etc/fstab /etc/fstab.bak
sudo vi /etc/fstab

fs-0123456789abcdef0:/  /mnt/efs  efs  _netdev,tls  0  0

sudo mount -a
df -hT /mnt/efs
Add the EFS line as one line in /etc/fstab. _netdev tells the system this is a network file system and should be mounted after networking is available. Back up fstab first; an invalid entry can affect boot.

vi quick keys: press i to insert; edit the line; press Esc; type :wq and press Enter to save and quit. Use :q! to quit without saving.

Step 4 — Create the packages directory and connect it to Nginx
Purpose: Create the directory on EFS that will store downloaded packages.
sudo mkdir -p /mnt/efs/packages
sudo ls -ld /mnt/efs /mnt/efs/packages
What the command means: mkdir -p = create the directory if it does not exist; ls -ld = show directory details and permissions.
Recommended method: keep the Nginx alias in Step 6. No symlink is needed.
Optional symlink method (use this only if you prefer a filesystem path under the web root):
sudo ln -s /mnt/efs/packages /usr/share/nginx/html/packages
ls -l /usr/share/nginx/html/packages
Do not use both the optional symlink and the alias for the same URL path. The supplied alias configuration is the cleaner choice.
Step 5 — Set directory and file permissions
Purpose: Allow Nginx to read the package directory and files without making them writable by everyone.
sudo find /mnt/efs/packages -type d -exec chmod 755 {} \;
sudo find /mnt/efs/packages -type f -exec chmod 644 {} \;

# Check permissions
find /mnt/efs/packages -maxdepth 2 -printf '%M %u:%g %p\n' | head
What the command means: find = locate files; -type d = directories; -type f = regular files; chmod = change permissions; 755 = owner can read/write/enter, everyone else can read/enter; 644 = owner can read/write, everyone else can read.
Why not 655? For ordinary RPMs, repodata, and metadata, execute permission is unnecessary. 644 is the standard read-only-for-others file mode. Also verify ownership and EFS access-point POSIX identity if you use an EFS access point.

Step 6 — Configure Nginx to publish the EFS packages
Purpose: Create an Nginx server configuration that serves the home page and exposes EFS packages at /packages/.
sudo vi /etc/nginx/conf.d/packages.conf
Add this configuration:
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /packages/ {
        alias /mnt/efs/packages/;

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;

        add_header X-Content-Type-Options nosniff;
    }
}
Save with Esc, :wq, Enter. The trailing slashes on both /packages/ and the alias path are intentional.
Directive meanings: listen 80 = listen on HTTP port 80; server_name _ = catch-all server name; root = document root; index = default page; try_files = look for the requested file or return 404; alias = map URL path to EFS directory; autoindex on = show directory listing; autoindex_exact_size off = human-readable sizes; autoindex_localtime on = show local timestamps; add_header = add an HTTP response header.

Step 7 — Test Nginx configuration and reload
Purpose: Check the configuration syntax before applying it.
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx
What the command means: nginx -t = test configuration; reload = apply changes without a full service stop; status = check whether Nginx is active.
Apache alternative: For Apache, the syntax test is sudo apachectl configtest (or sudo httpd -t). The Nginx server block above is not valid Apache configuration.

Step 8 — Create the home page
Purpose: Add a simple HTML page that links to the EFS package directory.
sudo vi /usr/share/nginx/html/index.html
Example HTML:
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Internal Package Repository</title>
</head>
<body>
  <h1>Internal Package Repository</h1>
  <p><a href="/packages/">Browse available packages</a></p>
</body>
</html>

sudo nginx -t && sudo systemctl reload nginx
&& means run the second command only if the first command succeeds.

Step 9 — Test locally and from a client
Purpose: Verify the home page and package listing respond successfully.
curl -I http://localhost/
curl -I http://localhost/packages/
curl -I http://YOUR_SERVER_PUBLIC_IP/
curl -I http://YOUR_SERVER_PUBLIC_IP/packages/
What the command means: curl = make an HTTP request; -I = request response headers only. Replace YOUR_SERVER_PUBLIC_IP with the instance's reachable IP or DNS name.
Expected result: HTTP/1.1 200 OK (or HTTP/2 200) for the home page and package directory. A 403 usually indicates permissions or Nginx access; a 404 usually indicates a wrong path or missing configuration; a timeout often indicates security-group, route, or network issues.
Important: If the instance is private, test through its private IP from a host in the VPC, or expose it through an approved load balancer/VPN. Do not open port 80 to the entire internet unless that is intended.

Step 10 — Synchronize packages from another server
Mount the same EFS file system on the package-sync server at /mnt/efs, then download packages into a staging directory and copy them to EFS. This avoids partially downloaded files being exposed to clients.
 
A. Install package synchronization tools
sudo dnf install -y dnf-plugins-core
sudo dnf install -y yum-utils
On Amazon Linux 2023, use DNF and confirm the installed tool provides the reposync command. yum-utils/yumdownloader may be available depending on enabled repositories and package versions.

B. Check repository IDs
dnf repolist
Use repository IDs that actually appear in this output. Repository IDs vary by operating-system release and enabled repositories. Do not blindly copy amzn2-core onto Amazon Linux 2023; that ID is associated with Amazon Linux 2 in many configurations.

C. Synchronize selected repositories
sudo mkdir -p /tmp/repo-sync
sudo reposync --download-path=/tmp/repo-sync --newest-only --repoid=<REPO_ID>
For more than one repository, repeat --repoid for each repository supported by your reposync version:
sudo reposync --download-path=/tmp/repo-sync --newest-only \\
  --repoid=<REPO_ID_1> \\
  --repoid=<REPO_ID_2>
Check your installed command's options with:
reposync --help

D. Copy the synchronized content to EFS
sudo mkdir -p /mnt/efs/packages
sudo rsync -avh /tmp/repo-sync/ /mnt/efs/packages/
sudo find /mnt/efs/packages -type d -exec chmod 755 {} \\\;
sudo find /mnt/efs/packages -type f -exec chmod 644 {} \\\;
rsync -avh = copy recursively while preserving useful attributes, show progress-style output, and use human-readable sizes. Confirm the exact directory layout created by reposync before copying.

E. Download only selected RPM packages and dependencies
mkdir -p /tmp/rpms
sudo yumdownloader --resolve --destdir=/tmp/rpms nginx httpd amazon-cloudwatch-agent
sudo rsync -avh /tmp/rpms/ /mnt/efs/packages/
sudo find /mnt/efs/packages -type f -exec chmod 644 {} \\\;
--resolve asks yumdownloader to include dependencies; --destdir chooses the output directory. The exact availability of yumdownloader and package names depends on enabled repositories. Check with dnf provides '*/yumdownloader' or install the package that supplies it for your OS.
Do not mix repository releases: Build a repository for the target OS and release. For example, do not sync Amazon Linux 2 repositories and assume the RPMs are suitable for Amazon Linux 2023. Also consider architecture (x86_64 vs aarch64).

F. Verify package files are visible over HTTP
ls -lah /mnt/efs/packages
curl -I http://localhost/packages/
curl -I http://YOUR_SERVER_PUBLIC_IP/packages/
If directory listing is disabled later for security, turn autoindex off and publish a repository metadata structure instead.

3. Useful command glossary — easy to remember
Command	Remember it as	Meaning / example
dnf install	Install a package	dnf install nginx = install Nginx
systemctl enable	Enable at boot	enable nginx = start automatically after reboot
systemctl start	Start now	start nginx = start the service
systemctl status	Show service state	status nginx = is it running?
mkdir -p	Make path	Create directory and missing parents
mount	Attach storage	Connect EFS to a Linux directory
df -hT	Disk free, human-readable, type	Check mounted storage
vi	Edit text file	i = insert; Esc :wq = save and quit
chmod	Change mode/permissions	755 directories; 644 ordinary files
ln -s	Link - symbolic	Create a shortcut/path to another directory
nginx -t	Nginx test	Validate configuration syntax
curl -I	HTTP headers only	Check web response status
reposync	Repository synchronize	Download repository content
yumdownloader --resolve	Download RPMs plus dependencies	Fetch selected packages
rsync -avh	Reliable file copy	Copy directory contents to EFS
find	Find files	Select directories or files for chmod

5. Troubleshooting checklist
•	EFS mount fails — Confirm mount target exists in the AZ, EC2 can reach it, EFS SG allows TCP 2049 from EC2 SG, and amazon-efs-utils is installed.
•	Mount disappears after reboot — Check the /etc/fstab entry, _netdev option, file-system ID, and run sudo mount -a.
•	Nginx returns 403 — Check execute permission on every parent directory and read permission on files; check EFS POSIX identity/access point; inspect /var/log/nginx/error.log.
•	Nginx returns 404 — Check /etc/nginx/conf.d/packages.conf, alias path, trailing slashes, and whether the package file exists.
•	Nginx config test fails — Run sudo nginx -t and fix the exact file/line reported before reloading.
•	curl times out remotely — Check EC2 inbound TCP 80, route tables, network ACLs, public IP/load balancer, and client network.
•	reposync fails — Run dnf repolist and reposync --help; verify repo ID, DNS/internet or proxy access, and package manager compatibility.

7. Final end-to-end validation
•	EFS is mounted at /mnt/efs and survives a reboot.
•	The directory /mnt/efs/packages exists and is readable by Nginx.
•	sudo nginx -t completes successfully.
•	http://SERVER-IP/ displays the HTML home page.
•	http://SERVER-IP/packages/ lists package files (if autoindex is enabled).
•	A second EC2 instance can mount the same EFS and see the same files.

