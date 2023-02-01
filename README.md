# Nextcloud Installer

This shell script automatically installs and configures the [**Nextcloud**](https://nextcloud.com/) server on Debian based Linux system.

## Development status

Working version done.

## Installation

These are the installation instructions of this software for Debian based Linux system.

**IMPORTANT NOTE**: It is recommended to install this software on a clean OS installation, otherwise it may cause that other software previously installed on your server could stop working properly due to this. You are using this software at your own risk.

Log in as "root" on your server and run the following commands to download the necessary dependencies and the latest version of this script from GitHub:

```console
apt update
apt -y upgrade
apt -y install git
git clone https://github.com/libersoft-org/nextcloud-install.git
cd nextcloud-install/
./install.sh
```

... and follow the installation instructions.

After the installation open your Nextcloud in web browser and proceed the rest of the installation.

## License
- This software is developed as open source under [**Unlicense**](./LICENSE).

## Donations

Donations are important to support the ongoing development and maintenance of our open source projects. Your contributions help us cover costs and support our team in improving our software. We appreciate any support you can offer.

To find out how to donate our projects, please navigate here:

[![Donate](https://raw.githubusercontent.com/libersoft-org/documents/main/donate.png)](https://libersoft.org/donations)

Thank you for being a part of our projects' success!
