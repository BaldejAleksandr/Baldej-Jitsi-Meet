#!/bin/sh
# Patches jitsi-meet-file-sharing-service sources before the build - Правки исходников jitsi-meet-file-sharing-service перед сборкой
# If a fragment is not found, the build fails instead of losing the patch - Если фрагмент не найден, сборка падает, чтобы правка не потерялась молча
set -eu

replace() {
    FROM="$2" TO="$3" node -e '
        const fs = require("fs");
        const f = process.argv[1];
        const src = fs.readFileSync(f, "utf8");
        if (!src.includes(process.env.FROM)) {
            console.error(`patch.sh: fragment not found in ${f}:\n${process.env.FROM}`);
            process.exit(1);
        }
        fs.writeFileSync(f, src.replace(process.env.FROM, process.env.TO));
    ' "$1"
}

# File size limit from MAX_FILE_SIZE_BYTES (10 MB hardcoded upstream) - Лимит размера файла из MAX_FILE_SIZE_BYTES (в оригинале 10 МБ в коде)
replace src/utils/multer.ts \
    'fileSize: 10 * 1024 * 1024' \
    'fileSize: Number(process.env.MAX_FILE_SIZE_BYTES) || 10 * 1024 * 1024'

# Allowed files come from ALLOWED_EXTENSIONS ("pdf,xlsx,ods") - Разрешённые файлы задаются списком в ALLOWED_EXTENSIONS ("pdf,xlsx,ods")
# The type is derived from the extension, not from the browser - Тип файла определяется по расширению, а не по тому, что прислал браузер
# Without Office/LibreOffice browsers send application/octet-stream - Без Office/LibreOffice браузер шлёт application/octet-stream
# The content check for executables (isExecutableBuffer) stays - Проверка на исполняемые файлы по содержимому (isExecutableBuffer) остаётся
replace src/utils/multer.ts \
    "import multer from 'multer';" \
    "import mime from 'mime-types';
import multer from 'multer';
import path from 'path';

const ALLOWED_EXTENSIONS = new Set(
    (process.env.ALLOWED_EXTENSIONS || '')
        .split(',')
        .map(ext => ext.trim().toLowerCase().replace(/^\\./, ''))
        .filter(Boolean)
);"

replace src/utils/multer.ts \
    '        if (!ALLOWED_MIME_TYPES.has(file.mimetype)) {
            cb(new Error(`File type not allowed: ${file.mimetype}`));

            return;
        }
        cb(null, true);' \
    '        const ext = path.extname(file.originalname).slice(1).toLowerCase();

        if (!ALLOWED_EXTENSIONS.has(ext)) {
            cb(new Error(`File type not allowed: .${ext}`));

            return;
        }
        file.mimetype = mime.lookup(ext) || '"'"'application/octet-stream'"'"';
        cb(null, true);'

# Total size limit of the uploads dir MAX_TOTAL_SIZE_BYTES (0: no limit) - Общий лимит объёма каталога загрузок MAX_TOTAL_SIZE_BYTES (0: без лимита)
# Before saving a file the oldest files are deleted until it fits - Перед сохранением файла самые старые удаляются, пока новый не поместится
# All files on disk count, including those left after a restart - Учитываются все файлы на диске, в том числе оставшиеся после перезапуска
replace src/services/fileStorage.ts \
    "const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';" \
    "const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const MAX_TOTAL_SIZE_BYTES = Number(process.env.MAX_TOTAL_SIZE_BYTES) || 0;

interface IStoredFile {
    filePath: string;
    mtime: number;
    size: number;
}"

replace src/services/fileStorage.ts \
    '    async saveFile(' \
    '    // Deletes the oldest files until the new file fits under MAX_TOTAL_SIZE_BYTES - Удаляет самые старые файлы, пока новый не поместится в MAX_TOTAL_SIZE_BYTES
    async makeRoom(incoming: number): Promise<void> {
        if (!MAX_TOTAL_SIZE_BYTES) return;

        if (incoming > MAX_TOTAL_SIZE_BYTES) {
            throw new Error(`File of ${incoming} bytes is larger than the storage limit`);
        }

        const stored: IStoredFile[] = [];

        for (const name of await fs.readdir(UPLOAD_DIR)) {
            const filePath = path.join(UPLOAD_DIR, name);

            try {
                const stat = await fs.stat(filePath);

                if (stat.isFile()) {
                    stored.push({ filePath, mtime: stat.mtimeMs, size: stat.size });
                }
            } catch {
                // the file was removed meanwhile - файл уже удалили
            }
        }
        stored.sort((a, b) => a.mtime - b.mtime);

        let total = stored.reduce((sum, f) => sum + f.size, 0);

        for (const f of stored) {
            if (total + incoming <= MAX_TOTAL_SIZE_BYTES) break;

            try {
                await fs.unlink(f.filePath);
            } catch {
                // already gone - уже удалён
            }
            total -= f.size;

            for (const [ id, record ] of this.fileRecords) {
                if (record.filePath === f.filePath) {
                    this.fileRecords.delete(id);
                }
            }
            console.log("Storage limit: removed oldest file", f.filePath);
        }
    }

    async saveFile('

replace src/services/fileStorage.ts \
    '    ): Promise<IFileRecord> {
        await this.ensureUploadDir();' \
    '    ): Promise<IFileRecord> {
        await this.ensureUploadDir();
        await this.makeRoom(file.size);'

# The service is behind proxies: without trust proxy every request has the nginx IP - Сервис стоит за прокси: без trust proxy все запросы приходят с IP nginx
# and rate limiting hits all users at once - и ограничение частоты запросов срабатывает сразу на всех пользователей
replace src/index.ts \
    "app.disable('x-powered-by');" \
    "app.disable('x-powered-by');
app.set('trust proxy', Number(process.env.TRUST_PROXY_HOPS) || 0);"
