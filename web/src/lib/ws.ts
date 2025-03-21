class WebSocketClient {
    private socket: WebSocket | null = null;
    private url: string;
    private onOpenCallback: (() => void) | null = null;
    private onMessageCallback: ((data: string) => void) | null = null;
    private onCloseCallback: ((code: number, reason: string) => void) | null =
        null;
    private onErrorCallback: ((event: Event) => void) | null = null;
    private reconnectInterval: number;
    private reconnectTimeoutId: number | null = null;

    constructor(url: string, reconnectInterval = 3000) {
        this.url = url;
        this.reconnectInterval = reconnectInterval;
    }

    public onOpen(callback: () => void): void {
        this.onOpenCallback = callback;
    }

    public onMessage(callback: (data: string) => void): void {
        this.onMessageCallback = callback;
    }

    public onClose(callback: (code: number, reason: string) => void): void {
        this.onCloseCallback = callback;
    }

    public onError(callback: (event: Event) => void): void {
        this.onErrorCallback = callback;
    }

    public connect(): void {
        this.socket = new WebSocket(this.url);

        this.socket.onopen = () => {
            console.log('WebSocket connected to:', this.url);
            if (this.onOpenCallback) {
                this.onOpenCallback();
            }
            if (this.reconnectTimeoutId !== null) {
                clearTimeout(this.reconnectTimeoutId);
                this.reconnectTimeoutId = null;
            }
        };

        this.socket.onmessage = (event: MessageEvent) => {
            if (this.onMessageCallback) {
                try {
                    this.onMessageCallback(event.data);
                } catch (error) {
                    console.error(error);
                }
            }
        };

        this.socket.onclose = (event: CloseEvent) => {
            this.socket = null; // Ensure socket is nullified on close
            if (this.onCloseCallback) {
                this.onCloseCallback(event.code, event.reason);
            }
            this.reconnect();
        };

        this.socket.onerror = (event: Event) => {
            if (this.onErrorCallback) {
                this.onErrorCallback(event);
            }
        };
    }

    public send(data: string): void {
        if (this.socket && this.socket.readyState === WebSocket.OPEN) {
            try {
                const payload =
                    typeof data === 'string' ? data : JSON.stringify(data);
                this.socket.send(payload);
            } catch (_error) {}
        } else {
            console.warn('WebSocket is not open.  Cannot send data.', data);
        }
    }

    public close(code?: number, reason?: string): void {
        if (this.socket) {
            this.socket.close(code, reason);
            this.socket = null;
        }
    }

    private reconnect(): void {
        if (this.reconnectTimeoutId === null) {
            this.reconnectTimeoutId = setTimeout(() => {
                this.connect();
                this.reconnectTimeoutId = null;
            }, this.reconnectInterval);
        }
    }
}

export default WebSocketClient;
