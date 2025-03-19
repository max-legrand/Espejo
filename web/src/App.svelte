<script lang="ts">
    import { onMount } from 'svelte';
    import WebSocketClient from './lib/ws';
    import { debounce } from 'lodash';

    let textContent = $state('');
    let isMobile = $state(false);
    let currentUpload = $state(null);
    let downloadUrl = $state('');

    // WebSocket setup
    const wsUrl = '/ws';
    const client = new WebSocketClient(wsUrl);
    client.onOpen(() => {
        client.send('Hello from the client! 👋');
    });
    client.onMessage((data: string) => {
        console.log('Received message from server:', data);
        textContent = data;
    });
    client.connect();

    // Debounce text changes
    const debouncedTextChange = debounce((text) => {
        // Send text to server or save it
        client.send(text);
    }, 500); // 0.5 seconds debounce

    function handleTextChange(event: Event) {
        if (event.target) {
            const textArea = event.target as HTMLTextAreaElement;
            textContent = textArea.value;
            debouncedTextChange(textContent);
        }
    }

    async function copyText() {
        await navigator.clipboard.writeText(textContent);
    }

    const handleFileUpload = async (event: Event) => {
        const inputElement = event.target as HTMLInputElement;
        if (inputElement.files && inputElement.files.length > 0) {
            const formData = new FormData();
            formData.append('file', inputElement.files[0]);

            const response = await fetch('/upload', {
                method: 'POST',
                body: formData,
            });

            const result = await response.json();
            if (response.ok && result.status === 'success') {
                await getUpload();
            }
        }
    };

    async function getUpload() {
        const currentUploadResponse = await fetch('/getUpload');
        try {
            const json = await currentUploadResponse.json();
            if (json.filename !== null && json.filename !== undefined) {
                currentUpload = json.filename;
                downloadUrl = `/download/${currentUpload}`;
            }
        } catch (error) {
            currentUpload = null;
        }
    }

    onMount(async () => {
        // Check if mobile
        const checkMobile = () => {
            isMobile = window.innerWidth <= 768;
        };

        checkMobile();
        window.addEventListener('resize', checkMobile);

        await getUpload();

        return new Promise(() => {
            window.removeEventListener('resize', checkMobile);
        });
    });
</script>

<main class="w-full text-white py-6">
    {#if !isMobile}
        <!-- Desktop Layout -->
        <div class="pl-4">
            <h2 class="text-2xl font-bold mb-4">Scratchpad</h2>
            <div class="flex">
                <!-- Left side with text area and copy button -->
                <div class="max-w-[1000px] w-full">
                    <div
                        class="border border-white rounded mb-4"
                        style="min-height: 180px;"
                    >
                        <textarea
                            class="w-full h-full focus:outline-none p-2 min-h-[180px]"
                            placeholder=""
                            value={textContent}
                            oninput={handleTextChange}
                            rows="15"
                        ></textarea>
                    </div>
                    {#if window.isSecureContext}
                        <button
                            class="border border-slate-950 rounded px-6 py-2 hover:bg-slate-800
                        bg-slate-600 font-medium"
                            onclick={copyText}
                        >
                            Copy
                        </button>
                    {/if}
                </div>

                <!-- Right side with file controls -->
                <div class="w-[250px] ml-8 mr-3 flex-shrink-0 flex flex-col">
                    {#if currentUpload}
                        <p class="mb-3 font-medium">File: {currentUpload}</p>
                        <a
                            href={downloadUrl}
                            class="border border-blue-950 rounded px-4 py-2 w-full
                        text-center mb-4 inline-block bg-blue-600 hover:bg-blue-800 font-medium"
                        >
                            Download
                        </a>
                    {/if}
                    <label
                        for="desktop-file-upload"
                        class="border border-indigo-950 rounded px-4 py-2 block
                        text-center cursor-pointer hover:bg-indigo-800 bg-indigo-600 font-medium"
                    >
                        Upload file
                    </label>
                    <input
                        id="desktop-file-upload"
                        type="file"
                        class="hidden"
                        onchange={handleFileUpload}
                    />
                </div>
            </div>
        </div>
    {:else}
        <!-- Mobile Layout -->
        <div class="px-4">
            <h2 class="text-xl font-bold mb-3">Scratchpad</h2>

            <div
                class="border border-white rounded mb-4"
                style="min-height: 150px;"
            >
                <textarea
                    class="w-full h-full focus:outline-none p-2 min-h-[150px]"
                    placeholder=""
                    value={textContent}
                    oninput={handleTextChange}
                ></textarea>
            </div>

            <button
                class="border border-slate-950 rounded px-6 py-2 hover:bg-slate-800
                        bg-slate-600 font-medium"
                onclick={copyText}
            >
                Copy
            </button>

            <div class="pt-4 flex flex-col">
                <p class="mb-3 font-medium">File: xyz.txt</p>
                <a
                    href={downloadUrl}
                    class="border border-blue-950 rounded px-4 py-2 w-full
                        text-center mb-4 inline-block bg-blue-600 hover:bg-blue-800 font-medium"
                >
                    Download
                </a>
                <label
                    for="desktop-file-upload"
                    class="border border-indigo-950 rounded px-4 py-2 block
                        text-center cursor-pointer hover:bg-indigo-800 bg-indigo-600 font-medium"
                >
                    Upload file
                </label>
                <input
                    id="mobile-file-upload"
                    type="file"
                    class="hidden"
                    onchange={handleFileUpload}
                />
            </div>
        </div>
    {/if}
</main>
