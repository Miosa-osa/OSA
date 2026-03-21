export type ConnectorType = "repo" | "server" | "app" | "custom";
export type ConnectorStatus = "connected" | "disconnected" | "error";

export interface Connector {
  id: string;
  name: string;
  type: ConnectorType;
  status: ConnectorStatus;
  url: string;
  description: string;
  lastSeen: string | null;
}

export interface DetectedService {
  name: string;
  port: number;
  type: ConnectorType;
  url: string;
}

export interface ConnectorFormValues {
  name: string;
  type: ConnectorType;
  url: string;
  description: string;
}
