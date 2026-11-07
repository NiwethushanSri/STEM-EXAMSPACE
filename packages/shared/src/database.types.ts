export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      audit_log: {
        Row: {
          action: string
          actor_id: string | null
          created_at: string
          id: number
          target_id: string | null
          target_type: string | null
        }
        Insert: {
          action: string
          actor_id?: string | null
          created_at?: string
          id?: never
          target_id?: string | null
          target_type?: string | null
        }
        Update: {
          action?: string
          actor_id?: string | null
          created_at?: string
          id?: never
          target_id?: string | null
          target_type?: string | null
        }
        Relationships: []
      }
      index_counters: {
        Row: {
          last: number
          year: number
        }
        Insert: {
          last: number
          year: number
        }
        Update: {
          last?: number
          year?: number
        }
        Relationships: []
      }
      login_attempts: {
        Row: {
          attempted_at: string
          key: string
        }
        Insert: {
          attempted_at?: string
          key: string
        }
        Update: {
          attempted_at?: string
          key?: string
        }
        Relationships: []
      }
      parent_children: {
        Row: {
          parent_id: string
          student_id: string
        }
        Insert: {
          parent_id: string
          student_id: string
        }
        Update: {
          parent_id?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "parent_children_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "parent_children_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      parent_link_blocks: {
        Row: {
          created_at: string
          parent_id: string
          student_id: string
        }
        Insert: {
          created_at?: string
          parent_id: string
          student_id: string
        }
        Update: {
          created_at?: string
          parent_id?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "parent_link_blocks_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "parent_link_blocks_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      parent_link_requests: {
        Row: {
          created_at: string
          id: string
          parent_id: string
          student_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          parent_id: string
          student_id: string
        }
        Update: {
          created_at?: string
          id?: string
          parent_id?: string
          student_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "parent_link_requests_parent_id_fkey"
            columns: ["parent_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "parent_link_requests_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      pending_invites: {
        Row: {
          created_at: string
          email: string
          invited_by: string | null
          role: Database["public"]["Enums"]["app_role"]
          token: string
        }
        Insert: {
          created_at?: string
          email: string
          invited_by?: string | null
          role: Database["public"]["Enums"]["app_role"]
          token?: string
        }
        Update: {
          created_at?: string
          email?: string
          invited_by?: string | null
          role?: Database["public"]["Enums"]["app_role"]
          token?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          email: string
          first_name: string
          id: string
          invite_sent_at: string | null
          last_name: string
          role: Database["public"]["Enums"]["app_role"]
          status: Database["public"]["Enums"]["account_status"]
        }
        Insert: {
          created_at?: string
          email: string
          first_name?: string
          id: string
          invite_sent_at?: string | null
          last_name?: string
          role: Database["public"]["Enums"]["app_role"]
          status: Database["public"]["Enums"]["account_status"]
        }
        Update: {
          created_at?: string
          email?: string
          first_name?: string
          id?: string
          invite_sent_at?: string | null
          last_name?: string
          role?: Database["public"]["Enums"]["app_role"]
          status?: Database["public"]["Enums"]["account_status"]
        }
        Relationships: []
      }
      student_details: {
        Row: {
          date_of_birth: string | null
          gender: string | null
          index_number: string | null
          parent_phone: string | null
          photo_path: string | null
          profile_id: string
          requested_by_parent: string | null
          school: string | null
          signup_parent_email: string | null
          signup_parent_name: string | null
          year_group: string | null
        }
        Insert: {
          date_of_birth?: string | null
          gender?: string | null
          index_number?: string | null
          parent_phone?: string | null
          photo_path?: string | null
          profile_id: string
          requested_by_parent?: string | null
          school?: string | null
          signup_parent_email?: string | null
          signup_parent_name?: string | null
          year_group?: string | null
        }
        Update: {
          date_of_birth?: string | null
          gender?: string | null
          index_number?: string | null
          parent_phone?: string | null
          photo_path?: string | null
          profile_id?: string
          requested_by_parent?: string | null
          school?: string | null
          signup_parent_email?: string | null
          signup_parent_name?: string | null
          year_group?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "student_details_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_details_requested_by_parent_fkey"
            columns: ["requested_by_parent"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      student_subjects: {
        Row: {
          student_id: string
          subject_id: number
        }
        Insert: {
          student_id: string
          subject_id: number
        }
        Update: {
          student_id?: string
          subject_id?: number
        }
        Relationships: [
          {
            foreignKeyName: "student_subjects_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "student_subjects_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
        ]
      }
      subjects: {
        Row: {
          active: boolean
          id: number
          kind: Database["public"]["Enums"]["subject_kind"]
          name: string
        }
        Insert: {
          active?: boolean
          id?: never
          kind: Database["public"]["Enums"]["subject_kind"]
          name: string
        }
        Update: {
          active?: boolean
          id?: never
          kind?: Database["public"]["Enums"]["subject_kind"]
          name?: string
        }
        Relationships: []
      }
      teacher_subjects: {
        Row: {
          subject_id: number
          teacher_id: string
        }
        Insert: {
          subject_id: number
          teacher_id: string
        }
        Update: {
          subject_id?: number
          teacher_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "teacher_subjects_subject_id_fkey"
            columns: ["subject_id"]
            isOneToOne: false
            referencedRelation: "subjects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "teacher_subjects_teacher_id_fkey"
            columns: ["teacher_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      tutor_students: {
        Row: {
          student_id: string
          tutor_id: string
        }
        Insert: {
          student_id: string
          tutor_id: string
        }
        Update: {
          student_id?: string
          tutor_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tutor_students_student_id_fkey"
            columns: ["student_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tutor_students_tutor_id_fkey"
            columns: ["tutor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      approve_student_tx: {
        Args: { p_actor: string; p_student: string; p_year?: number }
        Returns: {
          index_number: string
          invite_token: string
          parent_email: string
          parent_id: string
        }[]
      }
      can_manage_account: {
        Args: { p_action: string; p_actor: string; p_target: string }
        Returns: string
      }
      claim_invite: {
        Args: {
          p_email: string
          p_role: Database["public"]["Enums"]["app_role"]
          p_token: string
          p_user: string
        }
        Returns: string
      }
      claim_parent_invite: {
        Args: { p_email: string; p_token: string; p_user: string }
        Returns: string
      }
      clear_invite_tx: {
        Args: { p_actor: string; p_email: string }
        Returns: string
      }
      complete_profile: {
        Args: {
          p_gender: string
          p_parent_phone: string
          p_photo_path?: string
          p_subject_ids: number[]
          p_year_group: string
        }
        Returns: undefined
      }
      decide_parent_link_tx: {
        Args: { p_actor: string; p_approve: boolean; p_request: string }
        Returns: string
      }
      delete_account_tx: {
        Args: { p_actor: string; p_target: string }
        Returns: string
      }
      delete_own_account_tx: { Args: { p_user: string }; Returns: string }
      expire_unconfirmed: { Args: { p_now?: string }; Returns: number }
      is_staff_admin: { Args: never; Returns: boolean }
      link_children_to_parent: { Args: { p_parent: string }; Returns: number }
      link_student_to_parent: {
        Args: { p_parent: string; p_student: string }
        Returns: string
      }
      login_attempt_begin: {
        Args: { p_idx_key: string; p_ip_key: string }
        Returns: boolean
      }
      login_attempt_clear: { Args: { p_idx_key: string }; Returns: undefined }
      login_attempt_refund: {
        Args: { p_idx_key: string; p_ip_key: string }
        Returns: undefined
      }
      login_attempt_refund_key: { Args: { p_key: string }; Returns: undefined }
      login_attempt_succeed: {
        Args: { p_idx_key: string; p_ip_key: string }
        Returns: undefined
      }
      my_role: { Args: never; Returns: Database["public"]["Enums"]["app_role"] }
      purge_student_residue: { Args: { p_user: string }; Returns: undefined }
      register_child_tx: {
        Args: { p_child: string; p_parent: string }
        Returns: boolean
      }
      reject_student_tx: {
        Args: { p_actor: string; p_student: string }
        Returns: string
      }
      remove_staff_tx: {
        Args: { p_actor: string; p_target: string }
        Returns: string
      }
      request_parent_link_tx: {
        Args: { p_dob: string; p_index: string; p_parent: string }
        Returns: boolean
      }
      set_account_status_tx: {
        Args: { p_action: string; p_actor: string; p_target: string }
        Returns: string
      }
    }
    Enums: {
      account_status:
        | "unconfirmed"
        | "pending"
        | "profile_incomplete"
        | "active"
        | "suspended"
      app_role:
        | "owner"
        | "admin"
        | "teacher"
        | "tutor"
        | "corrector"
        | "student"
        | "parent"
      subject_kind: "school" | "entrance"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      account_status: [
        "unconfirmed",
        "pending",
        "profile_incomplete",
        "active",
        "suspended",
      ],
      app_role: [
        "owner",
        "admin",
        "teacher",
        "tutor",
        "corrector",
        "student",
        "parent",
      ],
      subject_kind: ["school", "entrance"],
    },
  },
} as const
