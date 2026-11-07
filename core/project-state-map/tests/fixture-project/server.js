import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
export const server = createServer(async (req, res) => res.end(await readFile('index.html')))
server.listen(8080)
