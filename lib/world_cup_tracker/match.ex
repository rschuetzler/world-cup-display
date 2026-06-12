defmodule WorldCupTracker.Match do
  @moduledoc """
  Normalized representation of a single World Cup match, independent of the
  upstream data source (ESPN or FIFA).
  """

  @type side :: %{
          name: String.t(),
          abbrev: String.t() | nil,
          score: non_neg_integer() | nil
        }

  @type state :: :scheduled | :live | :halftime | :finished

  @type t :: %__MODULE__{
          source: :espn | :fifa,
          id: String.t(),
          kickoff: DateTime.t(),
          round: String.t() | nil,
          home: side(),
          away: side(),
          state: state(),
          clock: String.t() | nil,
          detail: String.t() | nil
        }

  @enforce_keys [:source, :id, :kickoff, :home, :away, :state]
  defstruct [:source, :id, :kickoff, :round, :home, :away, :state, :clock, :detail]
end
