# mtpfs
Media Transfer Protocol support for macOS 26+

<img width="2064" height="1696" alt="image" src="https://github.com/user-attachments/assets/5b1cbd76-84e4-4538-82b0-ed9182500d44" />

## Installation
Download the [latest release](https://github.com/X1nto/mtpfs/releases/latest), open the .dmg file and drag the app to the Applications folder. Open the app.

1) You'll be asked to first enable the login items. Click on the "Open Login Items" button, which should open the system settings. Enable the MTPFS background daemon. You'll most likely be asked for your password, enter it.
2) The app will prompt you to enable the File System Extension. Click on the "Open File System Extensions" button.

   If you're on macOS 27+, the app will open the File System Extensions dialog automatically, check "mtp" in that dialog.

   If you're on macOS 26, you'll need to manually open the dialog. In the "Login Items" page, scroll down to "Extensions", click on "By Category" and look for "File System Extensions". Click on the little 'i' icon next to it. Tick "mtp".

## Contributing
All contributions are welcome! If you're here to fix a bug, please look at the [issues](https://github.com/X1nto/mtpfs/issues) page first. If an issue exists, feel free to pick it up, but please notify me beforehand. If an issue doesn't exist, create it and include in the body (or the subsequent comment) that you'd like to work on it.

Using LLMs is not discouraged as long as you understand what the code does and why. If you're using AI to contribute, please mention it beforehand, as it would help eliminate confusion when reviewing the pull request.

## Support
[<img src="https://github.com/user-attachments/assets/31f773e9-bfd7-46b1-b4dd-78621baa9a45" height="75">](https://ko-fi.com/xinto)

## License
```
mtpfs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
```
